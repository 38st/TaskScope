import Darwin
import Foundation

enum ShellCommandRunner {
    static func run(
        _ command: String,
        timeout: TimeInterval = 15
    ) async -> ShellCommandResult {
        let execution = CommandExecution(command: command, timeout: timeout)
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
        private let standardOutput = Pipe()
        private let standardError = Pipe()
        private let outputCapture = PipeCapture()
        private let errorCapture = PipeCapture()
        private let stateLock = NSLock()

        private var continuation: CheckedContinuation<ShellCommandResult, Never>?
        private var pendingResult: ShellCommandResult?
        private var completed = false
        private var processStarted = false
        private var processIdentifier: pid_t?
        private var childExitCode: Int32?
        private var stopEscalationFinished = false
        private var terminalOverride: (message: String, exitCode: Int32)?
        private var timeoutTask: Task<Void, Never>?
        private var killFallbackTask: Task<Void, Never>?

        init(command: String, timeout: TimeInterval) {
            self.command = command
            self.timeout = max(0.1, timeout)
        }

        func start(continuation: CheckedContinuation<ShellCommandResult, Never>) {
            stateLock.lock()
            self.continuation = continuation
            let alreadyCompleted = completed
            let pendingResult = self.pendingResult
            stateLock.unlock()

            if alreadyCompleted, let pendingResult {
                continuation.resume(returning: pendingResult)
                return
            }

            standardOutput.fileHandleForReading.readabilityHandler = { [outputCapture] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputCapture.append(data)
                }
            }

            standardError.fileHandleForReading.readabilityHandler = { [errorCapture] handle in
                let data = handle.availableData
                if !data.isEmpty {
                    errorCapture.append(data)
                }
            }

            stateLock.lock()
            guard !completed else {
                stateLock.unlock()
                return
            }

            let spawnResult = spawnContainedShell()
            switch spawnResult {
            case let .success(pid):
                processIdentifier = pid
                processStarted = true
                stateLock.unlock()

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    var status: Int32 = 0
                    var waitedPID: pid_t
                    repeat {
                        waitedPID = Darwin.waitpid(pid, &status, 0)
                    } while waitedPID == -1 && errno == EINTR

                    let exitCode: Int32
                    if waitedPID == pid {
                        exitCode = Self.exitCode(fromWaitStatus: status)
                    } else {
                        exitCode = -1
                    }
                    self?.childDidExit(exitCode: exitCode)
                }

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
                closePipeWriters()
                finish(
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
            requestStop(message: "Command cancelled.", exitCode: -2)
        }

        private func timeOut() {
            requestStop(
                message: "Command timed out after \(timeout) seconds.",
                exitCode: -3
            )
        }

        private func requestStop(message: String, exitCode: Int32) {
            stateLock.lock()
            guard !completed else {
                stateLock.unlock()
                return
            }
            if terminalOverride == nil {
                terminalOverride = (message, exitCode)
            }
            let didStart = processStarted
            stateLock.unlock()

            guard didStart else {
                finish(
                    ShellCommandResult(
                        command: command,
                        stdout: outputCapture.string,
                        stderr: message,
                        exitCode: exitCode
                    )
                )
                return
            }

            guard let processIdentifier = currentProcessIdentifier() else {
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

        private func childDidExit(exitCode: Int32) {
            stateLock.lock()
            childExitCode = exitCode
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
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            drainAvailableData(from: standardOutput, into: outputCapture)
            drainAvailableData(from: standardError, into: errorCapture)
            closePipeReaders()

            stateLock.lock()
            let terminalOverride = self.terminalOverride
            stateLock.unlock()
            let capturedError = errorCapture.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let reportedError: String
            if let terminalOverride {
                reportedError = capturedError.isEmpty
                    ? terminalOverride.message
                    : "\(capturedError)\n\(terminalOverride.message)"
            } else {
                reportedError = capturedError
            }

            finish(
                ShellCommandResult(
                    command: command,
                    stdout: outputCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: reportedError,
                    exitCode: terminalOverride?.exitCode ?? exitCode
                )
            )
        }

        private func finish(_ result: ShellCommandResult) {
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
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            closePipeWriters()
            closePipeReaders()
            continuation?.resume(returning: result)
        }

        private func spawnContainedShell() -> SpawnResult {
            let outputRead = standardOutput.fileHandleForReading.fileDescriptor
            let outputWrite = standardOutput.fileHandleForWriting.fileDescriptor
            let errorRead = standardError.fileHandleForReading.fileDescriptor
            let errorWrite = standardError.fileHandleForWriting.fileDescriptor

            makeNonBlocking(outputRead)
            makeNonBlocking(errorRead)

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

            errorCode = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            guard errorCode == 0 else { return .failure(errorCode) }
            errorCode = posix_spawnattr_setpgroup(&attributes, 0)
            guard errorCode == 0 else { return .failure(errorCode) }

            let arguments = ["/bin/zsh", "-c", command]
            var argv = arguments.map { strdup($0) } + [nil]
            defer { argv.dropLast().forEach { free($0) } }

            var environment = ProcessInfo.processInfo.environment
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
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                capture.append(Data(buffer.prefix(count)))
            }
        }

        private func closePipeWriters() {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
        }

        private func closePipeReaders() {
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }

        private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
            let signal = status & 0x7f
            if signal == 0 {
                return (status >> 8) & 0xff
            }
            return signal
        }
    }

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var string: String {
            lock.lock()
            defer {
                lock.unlock()
            }

            return String(data: data, encoding: .utf8) ?? ""
        }

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }
    }
}
