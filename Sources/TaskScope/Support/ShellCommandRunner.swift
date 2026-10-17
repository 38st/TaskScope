import Darwin
import Foundation

enum ShellCommandRunner {
    /// Exit code reported when the calling task was cancelled.
    static let cancelledExitCode: Int32 = -2
    /// Exit code reported when the command outlived its timeout.
    static let timedOutExitCode: Int32 = -3

    static func run(
        _ command: String,
        timeout: TimeInterval = 15,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        }
    ) async -> ShellCommandResult {
        let execution = CommandExecution(command: command, timeout: timeout, waitForChild: waitForChild)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            // An AppleScript literal cannot span source lines, but collapsing
            // newlines to spaces destroys shell syntax: `else` and `fi` are only
            // keywords after a command terminator. Emit the `\n` escape so the
            // string AppleScript hands to /bin/sh keeps its real line breaks.
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Keep dates and decimals in the C locale while preserving UTF-8 names.
    /// Remove inherited locale overrides and pin UTC so `ps lstart` identities
    /// do not change when the system time zone changes.
    static func childEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var sanitized = environment.filter { key, _ in
            key != "LANG" && !key.hasPrefix("LC_")
        }
        sanitized["LC_CTYPE"] = "UTF-8"
        sanitized["LC_TIME"] = "C"
        sanitized["LC_NUMERIC"] = "C"
        sanitized["TZ"] = "UTC0"
        return sanitized
    }

    /// The shell is started with `-f` (NO_RCS) so a user's `.zshenv` cannot
    /// alias or redefine the tools TaskScope parses, print into their output,
    /// or change the locale.
    static let shellArguments = ["/bin/zsh", "-f", "-c"]

    static func extendedRegexLiteral(_ value: String) -> String {
        let metacharacters = CharacterSet(charactersIn: "\\.^$|?*+()[]{}")
        return value.unicodeScalars.map { scalar in
            metacharacters.contains(scalar) ? "\\\(Character(scalar))" : String(Character(scalar))
        }.joined()
    }

    private final class CommandExecution: @unchecked Sendable {
        private enum SpawnResult {
            case success(pid_t)
            case failure(Int32)
        }

        private let command: String
        private let timeout: TimeInterval
        private let waitForChild: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
        private let standardOutput = Pipe()
        private let standardError = Pipe()
        private let outputCapture = PipeCapture()
        private let errorCapture = PipeCapture()
        private let stateLock = NSLock()
        private let ioQueue = DispatchQueue(label: "TaskScope.ShellCommandRunner.IO")

        private var continuation: CheckedContinuation<ShellCommandResult, Never>?
        private var pendingResult: ShellCommandResult?
        private var completed = false
        private var completionScheduled = false
        private var processStarted = false
        private var processIdentifier: pid_t?
        private var childExitCode: Int32?
        private var childTerminationSignal: Int32?
        private var childReaped = false
        private var stopEscalationFinished = false
        private var terminalOverride: (message: String, exitCode: Int32)?
        private var timeoutTask: Task<Void, Never>?
        private var killFallbackTask: Task<Void, Never>?
        private var outputSource: DispatchSourceRead?
        private var errorSource: DispatchSourceRead?
        private var exitSource: DispatchSourceProcess?

        init(
            command: String,
            timeout: TimeInterval,
            waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
        ) {
            self.command = command
            self.timeout = max(0.1, timeout)
            self.waitForChild = waitForChild
        }

        func start(continuation: CheckedContinuation<ShellCommandResult, Never>) {
            stateLock.lock()
            self.continuation = continuation
            let alreadyCompleted = completed
            let pendingResult = self.pendingResult
            if alreadyCompleted, let pendingResult {
                stateLock.unlock()
                continuation.resume(returning: pendingResult)
                return
            }
            // A stop request that arrived first (the task was cancelled before
            // this body ran, or cancellation raced this call) has claimed the
            // completion under this same lock. Never spawn behind it: the child
            // would run unkilled while the caller was told it was cancelled.
            guard !completionScheduled, terminalOverride == nil else {
                stateLock.unlock()
                return
            }

            configureReadSources()
            let spawnResult = spawnContainedShell()
            switch spawnResult {
            case let .success(pid):
                processIdentifier = pid
                processStarted = true
                let source = makeExitSource(for: pid)
                exitSource = source
                stateLock.unlock()

                source.resume()
                // Catch an already-exited child promptly. Registration is
                // asynchronous, so its handler must repeat this check.
                reapIfExited(pid)

                let newTimeoutTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.timeOut()
                }
                stateLock.lock()
                if completed {
                    stateLock.unlock()
                    newTimeoutTask.cancel()
                } else {
                    timeoutTask = newTimeoutTask
                    stateLock.unlock()
                }
            case let .failure(errorCode):
                stateLock.unlock()
                scheduleImmediateFinish(
                    ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: String(cString: strerror(errorCode)),
                        exitCode: -1
                    )
                )
            }
        }

        func cancel() {
            requestStop(message: "Command cancelled.", exitCode: ShellCommandRunner.cancelledExitCode)
        }

        private func timeOut() {
            requestStop(
                message: "Command timed out after \(timeout) seconds.",
                exitCode: ShellCommandRunner.timedOutExitCode
            )
        }

        /// Replaces a blocking `waitpid` on a worker thread: the exit source
        /// fires on the I/O queue and the child is reaped with WNOHANG.
        private func makeExitSource(for pid: pid_t) -> DispatchSourceProcess {
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: ioQueue
            )
            source.setEventHandler { [weak self] in
                self?.reapIfExited(pid, retryUntilReaped: true)
            }
            // resume() returns before kevent registration. A short-lived child
            // can exit after the first WNOHANG check but before registration,
            // leaving no transition for the event handler to observe.
            source.setRegistrationHandler { [weak self] in
                self?.reapIfExited(pid)
            }
            return source
        }

        private func reapIfExited(_ pid: pid_t, retryUntilReaped: Bool = false) {
            // Serialize the probes and stop probing once reaped: a delayed
            // registration callback must never wait on a reused PID.
            stateLock.lock()
            guard !childReaped else {
                stateLock.unlock()
                return
            }
            var status: Int32 = 0
            var waitedPID: pid_t
            repeat {
                waitedPID = waitForChild(pid, &status, WNOHANG)
            } while waitedPID == -1 && errno == EINTR
            guard waitedPID == pid else {
                stateLock.unlock()
                if waitedPID == 0, retryUntilReaped {
                    // NOTE_EXIT (including a synthesized registration event)
                    // can precede the child becoming waitable. It fires only
                    // once, so keep probing without blocking the I/O queue.
                    ioQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                        reapIfExited(pid, retryUntilReaped: true)
                    }
                }
                return
            }
            childReaped = true
            let source = exitSource
            exitSource = nil
            stateLock.unlock()
            source?.cancel()

            let (exitCode, signal) = Self.exitStatus(fromWaitStatus: status)
            childDidExit(exitCode: exitCode, terminationSignal: signal)
        }

        private func requestStop(message: String, exitCode: Int32) {
            // Continue probing after a stop even if no further exit event
            // arrives: the timeout task is no longer available as a backstop.
            if let pid = currentProcessIdentifier() {
                reapIfExited(pid, retryUntilReaped: true)
            }
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            // The child has already exited; its real exit is what gets reported,
            // not a cancellation or timeout that lost the race by a moment.
            guard !childReaped, childExitCode == nil else {
                stateLock.unlock()
                return
            }
            if terminalOverride == nil {
                terminalOverride = (message, exitCode)
            }
            guard processStarted else {
                // Claim completion under the same lock hold that observed "not
                // started", so a concurrent `start()` bails instead of spawning.
                completionScheduled = true
                stateLock.unlock()
                finishOnIOQueue(
                    ShellCommandResult(
                        command: command,
                        stdout: outputCapture.string,
                        stderr: message,
                        exitCode: exitCode
                    ),
                    closeWritersFirst: true
                )
                return
            }
            let processIdentifier = self.processIdentifier
            stateLock.unlock()

            guard let processIdentifier else {
                finishStoppedCommand()
                return
            }

            // The shell is atomically created as the leader of a new process
            // group. Signalling the negative group ID contains children and
            // grandchildren that inherit the shell's group.
            Darwin.kill(-processIdentifier, SIGTERM)

            let fallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.finishStopEscalation()
            }
            stateLock.lock()
            if completed {
                stateLock.unlock()
                fallback.cancel()
            } else {
                killFallbackTask?.cancel()
                killFallbackTask = fallback
                stateLock.unlock()
            }
        }

        private func currentProcessIdentifier() -> pid_t? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return processIdentifier
        }

        private func childDidExit(exitCode: Int32, terminationSignal: Int32?) {
            stateLock.lock()
            childExitCode = exitCode
            childTerminationSignal = terminationSignal
            let stopping = terminalOverride != nil
            stateLock.unlock()

            guard stopping else {
                finishAfterTermination(exitCode: exitCode)
                return
            }

            guard let processIdentifier = currentProcessIdentifier() else {
                finishStoppedCommand()
                return
            }

            errno = 0
            if Darwin.kill(-processIdentifier, 0) == -1, errno == ESRCH {
                markStopEscalationFinished()
            } else {
                // The group leader is already reaped, so anything still in the
                // group ignored TERM. Kill it immediately and avoid leaving a
                // reused group ID exposed to the delayed fallback.
                finishStopEscalation()
            }
        }

        private func finishStopEscalation() {
            if let processIdentifier = currentProcessIdentifier() {
                Darwin.kill(-processIdentifier, SIGKILL)
            }
            markStopEscalationFinished()
        }

        private func markStopEscalationFinished() {
            stateLock.lock()
            stopEscalationFinished = true
            let childExitCode = self.childExitCode
            stateLock.unlock()

            if childExitCode != nil {
                finishStoppedCommand()
            }
        }

        private func finishStoppedCommand() {
            stateLock.lock()
            let childExitCode = self.childExitCode
            let stopEscalationFinished = self.stopEscalationFinished
            stateLock.unlock()

            guard let childExitCode, stopEscalationFinished else { return }
            finishAfterTermination(exitCode: childExitCode)
        }

        private func finishAfterTermination(exitCode: Int32) {
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            completionScheduled = true
            let terminalOverride = self.terminalOverride
            let terminationSignal = childTerminationSignal
            stateLock.unlock()

            ioQueue.async { [self] in
                drainAvailableData(from: standardOutput, into: outputCapture)
                drainAvailableData(from: standardError, into: errorCapture)
                cancelReadSources()

                let capturedError = errorCapture.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let reportedError: String
                if let terminalOverride {
                    reportedError = capturedError.isEmpty
                        ? terminalOverride.message
                        : "\(capturedError)\n\(terminalOverride.message)"
                } else {
                    reportedError = capturedError
                }

                finishState(
                    ShellCommandResult(
                        command: command,
                        stdout: outputCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: reportedError,
                        exitCode: terminalOverride?.exitCode ?? exitCode,
                        // A signal TaskScope itself sent to stop the command is
                        // not the child's own termination story.
                        terminatedBySignal: terminalOverride == nil ? terminationSignal : nil
                    )
                )
            }
        }

        private func scheduleImmediateFinish(_ result: ShellCommandResult) {
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            completionScheduled = true
            stateLock.unlock()
            finishOnIOQueue(result, closeWritersFirst: true)
        }

        /// Drains and closes the pipes on the I/O queue, then completes. The
        /// caller must already hold the completion claim (`completionScheduled`).
        private func finishOnIOQueue(_ result: ShellCommandResult, closeWritersFirst: Bool) {
            ioQueue.async { [self] in
                // A cancellation can win before `start` configures nonblocking
                // readers or spawns the child. Close the writers first so an
                // otherwise blocking drain observes EOF immediately.
                if closeWritersFirst {
                    closePipeWriters()
                }
                drainAvailableData(from: standardOutput, into: outputCapture)
                drainAvailableData(from: standardError, into: errorCapture)
                cancelReadSources()
                finishState(result)
            }
        }

        private func finishState(_ result: ShellCommandResult) {
            stateLock.lock()
            guard !completed else {
                stateLock.unlock()
                return
            }
            completed = true
            pendingResult = result
            let continuation = self.continuation
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            let killFallbackTask = self.killFallbackTask
            self.killFallbackTask = nil
            stateLock.unlock()

            timeoutTask?.cancel()
            killFallbackTask?.cancel()
            // The exit source and any reap retries remain active until the
            // child is reaped, including after the timeout task has fired.
            closePipeWriters()
            continuation?.resume(returning: result)
        }

        private func configureReadSources() {
            let outputHandle = standardOutput.fileHandleForReading
            let errorHandle = standardError.fileHandleForReading
            let outputDescriptor = outputHandle.fileDescriptor
            let errorDescriptor = errorHandle.fileDescriptor
            makeNonBlocking(outputDescriptor)
            makeNonBlocking(errorDescriptor)

            let outputSource = DispatchSource.makeReadSource(
                fileDescriptor: outputDescriptor,
                queue: ioQueue
            )
            outputSource.setEventHandler { [outputCapture, outputSource] in
                Self.drain(descriptor: outputDescriptor, into: outputCapture)
                if outputCapture.isAtEOF {
                    outputSource.cancel()
                }
            }
            outputSource.setCancelHandler {
                try? outputHandle.close()
            }

            let errorSource = DispatchSource.makeReadSource(
                fileDescriptor: errorDescriptor,
                queue: ioQueue
            )
            errorSource.setEventHandler { [errorCapture, errorSource] in
                Self.drain(descriptor: errorDescriptor, into: errorCapture)
                if errorCapture.isAtEOF {
                    errorSource.cancel()
                }
            }
            errorSource.setCancelHandler {
                try? errorHandle.close()
            }

            self.outputSource = outputSource
            self.errorSource = errorSource
            outputSource.resume()
            errorSource.resume()
        }

        private func spawnContainedShell() -> SpawnResult {
            let outputRead = standardOutput.fileHandleForReading.fileDescriptor
            let outputWrite = standardOutput.fileHandleForWriting.fileDescriptor
            let errorRead = standardError.fileHandleForReading.fileDescriptor
            let errorWrite = standardError.fileHandleForWriting.fileDescriptor

            var fileActions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            var errorCode = posix_spawn_file_actions_init(&fileActions)
            guard errorCode == 0 else { return .failure(errorCode) }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            errorCode = posix_spawnattr_init(&attributes)
            guard errorCode == 0 else { return .failure(errorCode) }
            defer { posix_spawnattr_destroy(&attributes) }

            for (source, destination) in [(outputWrite, STDOUT_FILENO), (errorWrite, STDERR_FILENO)] {
                errorCode = posix_spawn_file_actions_adddup2(&fileActions, source, destination)
                guard errorCode == 0 else { return .failure(errorCode) }
            }
            for descriptor in [outputRead, errorRead, outputWrite, errorWrite] {
                errorCode = posix_spawn_file_actions_addclose(&fileActions, descriptor)
                guard errorCode == 0 else { return .failure(errorCode) }
            }

            // The child starts with default signal dispositions and an empty
            // signal mask regardless of what the parent inherited (a host that
            // ignores SIGTERM would otherwise make the stop path's SIGTERM a
            // no-op and misreport a signalled child as a normal exit).
            var defaultSignals = sigset_t()
            sigfillset(&defaultSignals)
            errorCode = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
            guard errorCode == 0 else { return .failure(errorCode) }
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            errorCode = posix_spawnattr_setsigmask(&attributes, &emptyMask)
            guard errorCode == 0 else { return .failure(errorCode) }

            errorCode = posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
            )
            guard errorCode == 0 else { return .failure(errorCode) }
            errorCode = posix_spawnattr_setpgroup(&attributes, 0)
            guard errorCode == 0 else { return .failure(errorCode) }

            let arguments = ShellCommandRunner.shellArguments + [command]
            var argv = arguments.map { strdup($0) } + [nil]
            defer { argv.dropLast().forEach { free($0) } }

            var environment = ShellCommandRunner.childEnvironment()
                .map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { environment.dropLast().forEach { free($0) } }

            var pid: pid_t = 0
            errorCode = posix_spawn(
                &pid,
                arguments[0],
                &fileActions,
                &attributes,
                &argv,
                &environment
            )
            guard errorCode == 0 else { return .failure(errorCode) }

            closePipeWriters()
            return .success(pid)
        }

        private func makeNonBlocking(_ descriptor: Int32) {
            let currentFlags = fcntl(descriptor, F_GETFL)
            if currentFlags != -1 {
                _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
            }
        }

        private func drainAvailableData(from pipe: Pipe, into capture: PipeCapture) {
            // Checked before `fileDescriptor` is touched, not just before the
            // read: reaching EOF cancels the stream's read source, whose cancel
            // handler closes this file handle, and `fileDescriptor` raises an
            // NSFileHandleOperationException on a closed handle. There is
            // nothing left to read anyway -- EOF means the capture already has
            // everything the writer sent.
            guard !capture.isAtEOF else { return }
            Self.drain(descriptor: pipe.fileHandleForReading.fileDescriptor, into: capture)
        }

        /// Reads everything currently available and records whether the stream
        /// reached EOF. The distinction matters: a pipe stays *permanently*
        /// readable once its writer closes, so a read source whose handler just
        /// returns at EOF is re-armed immediately and spins the I/O queue at
        /// 100% CPU. The source owner cancels on `capture.isAtEOF`.
        ///
        /// Once EOF is recorded the descriptor is never read again. Its cancel
        /// handler closes the file handle, and the number could by then name an
        /// unrelated reopened file.
        private static func drain(descriptor: Int32, into capture: PipeCapture) {
            guard !capture.isAtEOF else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    capture.append(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 {
                    capture.markEndOfFile()
                    return
                }
                let readError = errno
                if readError == EINTR {
                    continue
                }
                // EAGAIN (EWOULDBLOCK on Darwin) only means nothing is ready on
                // this nonblocking descriptor yet; the writer may still send
                // more. Any other error is unrecoverable, so it ends the stream
                // rather than leaving a source armed on a descriptor that can
                // only fail again.
                if readError != EAGAIN {
                    capture.markEndOfFile()
                }
                return
            }
        }

        private func cancelReadSources() {
            if let outputSource {
                outputSource.cancel()
                self.outputSource = nil
            } else {
                try? standardOutput.fileHandleForReading.close()
            }
            if let errorSource {
                errorSource.cancel()
                self.errorSource = nil
            } else {
                try? standardError.fileHandleForReading.close()
            }
        }

        private func closePipeWriters() {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
        }

        private static func exitStatus(fromWaitStatus status: Int32) -> (exitCode: Int32, signal: Int32?) {
            let signal = status & 0x7f
            if signal == 0 {
                return ((status >> 8) & 0xff, nil)
            }
            return (signal, signal)
        }
    }

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var reachedEndOfFile = false

        /// True once the writer closed and everything it wrote has been read.
        var isAtEOF: Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            return reachedEndOfFile
        }

        func markEndOfFile() {
            lock.lock()
            reachedEndOfFile = true
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer {
                lock.unlock()
            }

            // Lossy on purpose: a single invalid byte in a process name must not
            // erase the whole inventory.
            return String(decoding: data, as: UTF8.self)
        }

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }
    }
}
