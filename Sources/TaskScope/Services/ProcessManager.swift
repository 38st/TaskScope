import AppKit
import Darwin
import Foundation

@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var status: ProcessStatus = .idle
    @Published private(set) var watchedProcesses: WatchedProcessSnapshot = .none
    @Published private(set) var processes: [AppProcess] = []
    @Published private(set) var hasLoadedProcessList = false
    @Published private(set) var message: String = "Idle."
    @Published private(set) var isWorking = false

    let processListLimit = 80

    private let watchedProcessPattern = "GlobalProtect|PanGPA|PanGPS"
    private let currentPID = ProcessInfo.processInfo.processIdentifier

    init() {
        Task {
            await refreshWatchedStatus(showMessage: false)
        }
    }

    func refreshWatchedStatus(showMessage: Bool = true) async {
        await runAction {
            let watched = await currentWatchedProcesses()
            apply(watched)

            if showMessage {
                message = watched.detail
            }
        }
    }

    func loadProcessList(showMessage: Bool = true) async {
        await runAction {
            async let watchedSnapshot = currentWatchedProcesses()
            async let runningSnapshot = currentProcessList()

            let watched = await watchedSnapshot
            let running = await runningSnapshot

            apply(watched)
            processes = running
            hasLoadedProcessList = true

            if showMessage {
                message = "Loaded top \(running.count) processes."
            }
        }
    }

    func openGlobalProtect() async {
        await runAction {
            let url = URL(fileURLWithPath: "/Applications/GlobalProtect.app")
            let didOpen = NSWorkspace.shared.open(url)
            await refreshAfterMutation()

            message = didOpen ? "Opening GlobalProtect." : "Could not open GlobalProtect."
        }
    }

    func quitGlobalProtect() async {
        await runAction {
            let before = await currentWatchedProcesses()
            _ = await ShellCommandRunner.run("/usr/bin/pkill -x 'GlobalProtect' 2>/dev/null || true")
            await settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.globalProtect && !watchedProcesses.globalProtect {
                message = "No GlobalProtect app found."
            } else if !watchedProcesses.globalProtect {
                message = "GlobalProtect quit."
            } else {
                message = "GlobalProtect may still run."
            }
        }
    }

    func quitHelpers() async {
        await runAction {
            let before = await currentWatchedProcesses()
            _ = await ShellCommandRunner.run("/usr/bin/pkill -f '[P]anGPA' 2>/dev/null || true")
            await settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.panGPA && !watchedProcesses.panGPA {
                message = "No user helper found."
            } else if !watchedProcesses.panGPA {
                message = "User helper quit."
            } else {
                message = "User helper may still run."
            }
        }
    }

    func quitAllWatched() async {
        await runAction {
            let before = await currentWatchedProcesses()
            _ = await ShellCommandRunner.run("/usr/bin/pkill -x 'GlobalProtect' 2>/dev/null || true")
            _ = await ShellCommandRunner.run("/usr/bin/pkill -f '[P]anGPA' 2>/dev/null || true")
            await settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.globalProtect && !before.panGPA && !watchedProcesses.globalProtect && !watchedProcesses.panGPA {
                message = "No watched processes found."
            } else if watchedProcesses.globalProtect {
                message = "GlobalProtect may still run."
            } else if watchedProcesses.panGPA {
                message = "User helper may still run."
            } else {
                message = "App/user helper quit."
            }
        }
    }

    func terminate(_ process: AppProcess) async {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return
        }

        await runAction {
            let result = Darwin.kill(process.pid, SIGTERM)
            await settleAfterProcessChange()
            await refreshAfterMutation()

            let stillRunning = isProcessAlive(process.pid)

            if !stillRunning {
                message = "\(process.name) stopped."
            } else if result == 0 {
                message = "\(process.name) may still run."
            } else {
                message = "Could not stop \(process.name)."
            }
        }
    }

    func isCurrentProcess(_ process: AppProcess) -> Bool {
        process.pid == currentPID
    }

    private func refreshAfterMutation() async {
        if hasLoadedProcessList {
            async let watchedSnapshot = currentWatchedProcesses()
            async let runningSnapshot = currentProcessList()

            let watched = await watchedSnapshot
            let running = await runningSnapshot

            apply(watched)
            processes = running
        } else {
            let watched = await currentWatchedProcesses()
            apply(watched)
        }
    }

    private func settleAfterProcessChange() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    private func currentWatchedProcesses() async -> WatchedProcessSnapshot {
        let result = await ShellCommandRunner.run("/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(watchedProcessPattern))")

        guard result.exitCode == 0 else {
            return .none
        }

        let names = Set(
            result.stdout
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let parts = line.split(
                        separator: " ",
                        maxSplits: 1,
                        omittingEmptySubsequences: true
                    )

                    guard parts.count == 2 else {
                        return nil
                    }

                    return String(parts[1])
                }
        )

        return WatchedProcessSnapshot(
            globalProtect: names.contains("GlobalProtect"),
            panGPA: names.contains("PanGPA"),
            panGPS: names.contains("PanGPS")
        )
    }

    private func currentProcessList() async -> [AppProcess] {
        let command = "/bin/ps -arcwwwxo pid=,pcpu=,pmem=,comm= | /usr/bin/head -n \(processListLimit)"
        let result = await ShellCommandRunner.run(command)

        guard result.succeeded else {
            return []
        }

        return result.stdout
            .split(separator: "\n")
            .compactMap(parseProcessLine)
            .sorted { lhs, rhs in
                if lhs.cpu == rhs.cpu {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }

                return lhs.cpu > rhs.cpu
            }
    }

    private func parseProcessLine(_ line: Substring) -> AppProcess? {
        let parts = line.split(
            separator: " ",
            maxSplits: 3,
            omittingEmptySubsequences: true
        )

        guard parts.count == 4,
              let pid = Int32(parts[0]),
              let cpu = Double(parts[1]),
              let memory = Double(parts[2])
        else {
            return nil
        }

        return AppProcess(
            pid: pid,
            cpu: cpu,
            memory: memory,
            command: String(parts[3])
        )
    }

    private func apply(_ snapshot: WatchedProcessSnapshot) {
        watchedProcesses = snapshot
        status = snapshot.status
    }

    private func runAction(_ operation: () async -> Void) async {
        guard !isWorking else {
            return
        }

        isWorking = true
        defer {
            isWorking = false
        }

        await operation()
    }
}

enum ShellCommandRunner {
    static func run(_ command: String) async -> ShellCommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let outputCapture = PipeCapture()
            let errorCapture = PipeCapture()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = standardOutput
            process.standardError = standardError

            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData

                if !data.isEmpty {
                    outputCapture.append(data)
                }
            }

            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData

                if !data.isEmpty {
                    errorCapture.append(data)
                }
            }

            process.terminationHandler = { finishedProcess in
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil

                outputCapture.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
                errorCapture.append(standardError.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(
                    returning: ShellCommandResult(
                        command: command,
                        stdout: outputCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: errorCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        exitCode: finishedProcess.terminationStatus
                    )
                )
            }

            do {
                try process.run()
            } catch {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil

                continuation.resume(
                    returning: ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: error.localizedDescription,
                        exitCode: -1
                    )
                )
            }
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
