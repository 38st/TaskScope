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

    func setMessage(_ text: String) {
        message = text
    }
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
        guard pid != currentPID else { return }

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
        selectedPids = Set(processes.map { $0.pid }.filter { $0 != currentPID })
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
            await ProcessLifecycleController.settleAfterProcessChange()

            if !forceKill {
                for pid in pids where pid != currentPID && isProcessAlive(pid) {
                    Darwin.kill(pid, SIGKILL)
                }
                await ProcessLifecycleController.settleAfterProcessChange()
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
            let beforeOpen = await currentSnapshot(for: preset)
            let didOpen = beforeOpen.isMainRunning ? true : await ProcessLifecycleController.openAppBundle(at: preset.appPath)
            if !beforeOpen.isMainRunning {
                _ = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset)
                await ProcessLifecycleController.waitForProcessNamed(preset.mainProcessName, timeoutSeconds: 3)
            }
            let daemonResult = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset)
            await refreshAfterMutation()

            let now = snapshot(for: preset)
            let daemonDetail = daemonResult.messageSuffix
            if now.isMainRunning {
                if daemonResult.didChangeState {
                    message = "Opening \(preset.displayName)\(daemonDetail)."
                } else {
                    message = "Opening \(preset.displayName)."
                }
            } else if daemonResult == .failed {
                message = "\(preset.displayName) service needs admin approval."
            } else {
                message = didOpen ? "Opening \(preset.displayName)." : "Could not open \(preset.displayName)."
            }
        }
    }

    func quitMainApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.isMainRunning ? await ProcessLifecycleController.unloadUserLaunchAgents(for: preset) : false
            await ProcessLifecycleController.terminateProcess(named: preset.mainProcessName, forceIfStillRunning: true)
            await ProcessLifecycleController.settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.isMainRunning && !snapshot(for: preset).isMainRunning {
                message = "No \(preset.displayName) app found."
            } else if !snapshot(for: preset).isMainRunning {
                message = unloadedAgents ? "\(preset.displayName) quit and launch agents unloaded." : "\(preset.displayName) quit."
            } else {
                message = "\(preset.displayName) may still run."
            }
        }
    }

    func quitHelpers(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.hasHelpers ? await ProcessLifecycleController.unloadUserLaunchAgents(for: preset) : false
            for name in preset.helperProcessNames {
                await ProcessLifecycleController.terminateProcess(named: name, forceIfStillRunning: true)
            }
            await ProcessLifecycleController.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if before.helpersRunning.isEmpty && nowHelpers.isEmpty {
                message = "No user helpers found."
            } else if nowHelpers.isEmpty {
                message = unloadedAgents ? "User helpers quit and launch agents unloaded." : "User helpers quit."
            } else {
                message = "User helpers may still run."
            }
        }
    }

    func quitAllKillable(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.hasAny ? await ProcessLifecycleController.unloadUserLaunchAgents(for: preset) : false
            for name in preset.killableNames {
                await ProcessLifecycleController.terminateProcess(named: name, forceIfStillRunning: true)
            }
            await ProcessLifecycleController.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if !before.hasAny && !nowSnap.hasAny {
                message = "No watched processes found."
            } else if nowSnap.isMainRunning {
                message = "\(preset.displayName) may still run."
            } else if !nowSnap.helpersRunning.isEmpty {
                message = "User helpers may still run."
            } else {
                message = unloadedAgents ? "\(preset.displayName) closed and launch agents unloaded." : "\(preset.displayName) and helpers quit."
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
            await ProcessLifecycleController.settleAfterProcessChange()

            if isProcessAlive(process.pid) {
                if forceKill {
                    message = "Could not stop \(process.name)."
                } else {
                    Darwin.kill(process.pid, SIGKILL)
                    await ProcessLifecycleController.settleAfterProcessChange()

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
        let results = await withTaskGroup(of: (WatchedAppPreset, Set<String>).self) { group in
            for preset in presets {
                group.addTask { [self] in
                    let running = await self.checkRunningNames(for: preset)
                    return (preset, running)
                }
            }
            var collected: [(WatchedAppPreset, Set<String>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        return results.map { WatchedAppSnapshot(preset: $0, runningNames: $1) }
    }

    private func currentSnapshot(for preset: WatchedAppPreset) async -> WatchedAppSnapshot {
        let running = await checkRunningNames(for: preset)
        return WatchedAppSnapshot(preset: preset, runningNames: running)
    }

    private func checkRunningNames(for preset: WatchedAppPreset) async -> Set<String> {
        let nameResults = await withTaskGroup(of: (String, Bool).self) { group in
            for name in preset.allProcessNames {
                group.addTask {
                    let result = await ShellCommandRunner.run(
                        "/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(name))"
                    )
                    let isRunning = result.exitCode == 0 && result.stdout.split(separator: "\n").contains { line in
                        line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).count == 2
                    }
                    return (name, isRunning)
                }
            }
            var collected: [(String, Bool)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        return Set(nameResults.filter { $0.1 }.map { $0.0 })
    }

    @Published var fetchExtendedStats: Bool = false

    private func currentProcessList() async -> [AppProcess] {
        let limit = processListLimitProvider?() ?? 80
        return await ProcessListReader.currentProcessList(
            limit: limit,
            fetchExtendedStats: fetchExtendedStats
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
