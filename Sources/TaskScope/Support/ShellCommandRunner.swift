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
        private let command: String
        private let timeout: TimeInterval
        private let process = Process()
        private let standardOutput = Pipe()
        private let standardError = Pipe()
        private let outputCapture = PipeCapture()
        private let errorCapture = PipeCapture()
        private let stateLock = NSLock()

        private var continuation: CheckedContinuation<ShellCommandResult, Never>?
        private var pendingResult: ShellCommandResult?
        private var completed = false
        private var processStarted = false
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

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardOutput = standardOutput
            process.standardError = standardError

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

            process.terminationHandler = { [weak self] finishedProcess in
                self?.finishAfterTermination(exitCode: finishedProcess.terminationStatus)
            }

            stateLock.lock()
            guard !completed else {
                stateLock.unlock()
                return
            }

            do {
                try process.run()
                processStarted = true
                stateLock.unlock()

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
            } catch {
                stateLock.unlock()
                finish(
                    ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: error.localizedDescription,
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

            if process.isRunning {
                process.terminate()
            }

            let fallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.forceKillIfRunning()
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

        private func forceKillIfRunning() {
            guard process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }

        private func finishAfterTermination(exitCode: Int32) {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            outputCapture.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            errorCapture.append(standardError.fileHandleForReading.readDataToEndOfFile())

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
            process.terminationHandler = nil
            continuation?.resume(returning: result)
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
