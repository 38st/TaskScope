import AppKit
import Darwin
import Foundation
import Combine

@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var status: ProcessStatus = .idle
    @Published private(set) var snapshots: [WatchedAppSnapshot] = []
    @Published private(set) var processes: [AppProcess] = []
    @Published private(set) var hasLoadedProcessList = false
    @Published private(set) var message: String = "Idle."
    @Published private(set) var isWorking = false

    @Published var sortKey: ProcessSortKey = .cpu {
        didSet { resortProcesses() }
    }

    @Published private(set) var selectedPids: Set<Int32> = []

    var enableNotifications: Bool = true

    private var pollingTask: Task<Void, Never>?
    private var pollInterval: TimeInterval = 10
    private var pollProcessList = false

    private let currentPID = ProcessInfo.processInfo.processIdentifier

    deinit {
        pollingTask?.cancel()
    }

    func setPolling(interval: TimeInterval, includeProcessList: Bool) {
        pollInterval = max(2, interval)
        pollProcessList = includeProcessList
        restartPolling()
    }

    func restartPolling() {
        pollingTask?.cancel()
        pollInterval = max(2, pollInterval)
        let interval = pollInterval
        let includeList = pollProcessList
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                await self.refreshWatchedStatus(showMessage: false)
                if includeList, self.hasLoadedProcessList {
                    await self.loadProcessList(showMessage: false)
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func toggleSelection(_ pid: Int32) {
        if selectedPids.contains(pid) {
            selectedPids.remove(pid)
        } else {
            selectedPids.insert(pid)
        }
    }

    func clearSelection() {
        selectedPids.removeAll()
    }

    func selectAll() {
        selectedPids = Set(processes.map { $0.pid })
    }

    func batchTerminate(forceKill: Bool = false) async {
        let pids = selectedPids
        guard !pids.isEmpty else {
            message = "Nothing selected."
            return
        }
        await runAction {
            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            for pid in pids where pid != currentPID {
                Darwin.kill(pid, signal)
            }
            await settleAfterProcessChange()

            if !forceKill {
                for pid in pids where pid != currentPID && isProcessAlive(pid) {
                    Darwin.kill(pid, SIGKILL)
                }
                await settleAfterProcessChange()
            }

            let stopped = pids.filter { !isProcessAlive($0) }.count
            selectedPids.removeAll()
            message = "Stopped \(stopped) of \(pids.count) selected."
            await refreshAfterMutation()
        }
    }

    func refreshWatchedStatus(showMessage: Bool = true) async {
        await runAction {
            let watched = await currentSnapshots()
            apply(watched)

            if showMessage {
                message = watched.aggregateDetail
            }
        }
    }

    func refreshWatchedStatusUnchecked(showMessage: Bool = false) async {
        let watched = await currentSnapshots()
        apply(watched)
        if showMessage {
            message = watched.aggregateDetail
        }
    }

    func loadProcessList(showMessage: Bool = true) async {
        await runAction {
            async let snapshotsTask = currentSnapshots()
            async let runningTask = currentProcessList()

            let watched = await snapshotsTask
            let running = await runningTask

            apply(watched)
            processes = running
            hasLoadedProcessList = true
            resortProcesses()

            if showMessage {
                message = "Loaded \(running.count) processes."
            }
        }
    }

    func openApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let url = URL(fileURLWithPath: preset.appPath)
            let didOpen = NSWorkspace.shared.open(url)
            await refreshAfterMutation()
            message = didOpen ? "Opening \(preset.displayName)." : "Could not open \(preset.displayName)."
        }
    }

    func quitMainApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            _ = await ShellCommandRunner.run("/usr/bin/pkill -x \(ShellCommandRunner.shellQuoted(preset.mainProcessName)) 2>/dev/null || true")
            await settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.isMainRunning && !snapshot(for: preset).isMainRunning {
                message = "No \(preset.displayName) app found."
            } else if !snapshot(for: preset).isMainRunning {
                message = "\(preset.displayName) quit."
            } else {
                message = "\(preset.displayName) may still run."
            }
        }
    }

    func quitHelpers(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            for name in preset.helperProcessNames {
                _ = await ShellCommandRunner.run("/usr/bin/pkill -f \(ShellCommandRunner.shellQuoted("[\(name.prefix(1))]\(name.dropFirst())")) 2>/dev/null || true")
            }
            await settleAfterProcessChange()
            await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if before.helpersRunning.isEmpty && nowHelpers.isEmpty {
                message = "No user helpers found."
            } else if nowHelpers.isEmpty {
                message = "User helpers quit."
            } else {
                message = "User helpers may still run."
            }
        }
    }

    func quitAllKillable(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            for name in preset.killableNames {
                _ = await ShellCommandRunner.run("/usr/bin/pkill -x \(ShellCommandRunner.shellQuoted(name)) 2>/dev/null || true")
            }
            await settleAfterProcessChange()
            await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if !before.hasAny && !nowSnap.hasAny {
                message = "No watched processes found."
            } else if nowSnap.isMainRunning {
                message = "\(preset.displayName) may still run."
            } else if !nowSnap.helpersRunning.isEmpty {
                message = "User helpers may still run."
            } else {
                message = "\(preset.displayName) and helpers quit."
            }
        }
    }

    func terminate(_ process: AppProcess, forceKill: Bool = false) async {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return
        }

        await runAction {
            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            let result = Darwin.kill(process.pid, signal)
            await settleAfterProcessChange()

            if isProcessAlive(process.pid) {
                if forceKill {
                    message = "Could not stop \(process.name)."
                } else {
                    Darwin.kill(process.pid, SIGKILL)
                    await settleAfterProcessChange()

                    if isProcessAlive(process.pid) {
                        message = "Could not stop \(process.name)."
                    } else {
                        message = "\(process.name) force stopped."
                    }
                }
            } else if result == 0 {
                message = "\(process.name) stopped."
            } else {
                message = "Could not stop \(process.name)."
            }

            await refreshAfterMutation()
        }
    }

    func detail(for process: AppProcess) async -> ProcessDetail? {
        let result = await ShellCommandRunner.run(
            "/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(process.pid)"
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }

        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard tokens.count >= 8,
              let pid = Int32(tokens[0]),
              let ppid = Int32(tokens[1]) else {
            return nil
        }

        let user = tokens[2]
        let startTime = tokens[3..<8].joined(separator: " ")
        let command = tokens[8...].joined(separator: " ")

        return ProcessDetail(
            pid: pid,
            parentPID: ppid,
            user: user,
            startTime: startTime,
            command: command
        )
    }

    func isCurrentProcess(_ process: AppProcess) -> Bool {
        process.pid == currentPID
    }

    var ppidMap: [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for p in processes { map[p.pid] = p.parentPID }
        return map
    }

    private func refreshAfterMutation() async {
        if hasLoadedProcessList {
            async let snapshotsTask = currentSnapshots()
            async let runningTask = currentProcessList()

            let watched = await snapshotsTask
            let running = await runningTask

            apply(watched)
            processes = running
            resortProcesses()
        } else {
            let watched = await currentSnapshots()
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

    private func snapshot(for preset: WatchedAppPreset) -> WatchedAppSnapshot {
        snapshots.first(where: { $0.preset.id == preset.id }) ?? WatchedAppSnapshot(preset: preset, runningNames: [])
    }

    private func currentSnapshots() async -> [WatchedAppSnapshot] {
        let presets = watchedAppsProvider?() ?? []
        var runningByPreset: [(WatchedAppPreset, Set<String>)] = []

        for preset in presets {
            var running = Set<String>()
            for name in preset.allProcessNames {
                let result = await ShellCommandRunner.run(
                    "/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(name))"
                )
                guard result.exitCode == 0 else { continue }
                if result.stdout.split(separator: "\n").contains(where: { line in
                    line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).count == 2
                }) {
                    running.insert(name)
                }
            }
            runningByPreset.append((preset, running))
        }

        return runningByPreset.map { WatchedAppSnapshot(preset: $0.0, runningNames: $0.1) }
    }

    private func currentSnapshot(for preset: WatchedAppPreset) async -> WatchedAppSnapshot {
        var running = Set<String>()
        for name in preset.allProcessNames {
            let result = await ShellCommandRunner.run(
                "/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(name))"
            )
            guard result.exitCode == 0 else { continue }
            if result.stdout.split(separator: "\n").contains(where: { line in
                line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).count == 2
            }) {
                running.insert(name)
            }
        }
        return WatchedAppSnapshot(preset: preset, runningNames: running)
    }

    private func currentProcessList() async -> [AppProcess] {
        let limit = processListLimitProvider?() ?? 80
        let command = "/bin/ps -arcwwwxo pid=,ppid=,pcpu=,rss=,etime=,comm= | /usr/bin/head -n \(limit)"
        let result = await ShellCommandRunner.run(command)

        guard result.succeeded else {
            return []
        }

        var parsed = result.stdout
            .split(separator: "\n")
            .compactMap(parseProcessLine)

        let netStats = await currentNetworkStats()
        let diskStats = await currentDiskStats()
        for index in parsed.indices {
            parsed[index].netInKB = netStats[parsed[index].pid]?.0 ?? 0
            parsed[index].netOutKB = netStats[parsed[index].pid]?.1 ?? 0
            parsed[index].diskReadBlocks = diskStats[parsed[index].pid]?.0 ?? 0
            parsed[index].diskWriteBlocks = diskStats[parsed[index].pid]?.1 ?? 0
        }
        return parsed
    }

    private func currentNetworkStats() async -> [Int32: (Double, Double)] {
        let result = await ShellCommandRunner.run(
            "/usr/bin/nettop -P -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null || true"
        )
        guard result.succeeded else { return [:] }
        var stats: [Int32: (Double, Double)] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let namePid = parts[0]
            guard let dotIndex = namePid.lastIndex(of: "."),
                  let pid = Int32(namePid[namePid.index(after: dotIndex)...]),
                  let inBytes = Double(parts[1]),
                  let outBytes = Double(parts[2]) else { continue }
            stats[pid] = (inBytes / 1024.0, outBytes / 1024.0)
        }
        return stats
    }

    private func currentDiskStats() async -> [Int32: (Double, Double)] {
        let result = await ShellCommandRunner.run(
            "/bin/ps -axo pid=,inblock=,oublock= 2>/dev/null || true"
        )
        guard result.succeeded else { return [:] }
        var stats: [Int32: (Double, Double)] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]),
                  let r = Double(parts[1]),
                  let w = Double(parts[2]) else { continue }
            stats[pid] = (r, w)
        }
        return stats
    }

    private func parseProcessLine(_ line: Substring) -> AppProcess? {
        let parts = line.split(
            separator: " ",
            maxSplits: 4,
            omittingEmptySubsequences: true
        )

        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let cpu = Double(parts[2]),
              let rssKB = Double(parts[3]) else {
            return nil
        }

        return AppProcess(
            pid: pid,
            parentPID: ppid,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            command: String(parts[4]),
            elapsedTime: String(parts[3]),
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }

    private func resortProcesses() {
        processes.sort { lhs, rhs in
            switch sortKey {
            case .cpu:
                if lhs.cpu == rhs.cpu {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.cpu > rhs.cpu
            case .memory:
                if lhs.memoryMB == rhs.memoryMB {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.memoryMB > rhs.memoryMB
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .pid:
                return lhs.pid < rhs.pid
            }
        }
    }

    private func apply(_ watched: [WatchedAppSnapshot]) {
        snapshots = watched
        status = watched.aggregateStatus

        if enableNotifications {
            let running = Set(watched.filter { $0.preset.notificationsEnabled }.flatMap { $0.runningNames })
            NotificationService.shared.diffAndNotify(currentRunningNames: running)
        }
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

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
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
            process.arguments = ["-c", command]
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
