import Darwin
import Foundation
import Combine

protocol ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool
    func isAlive(_ pid: Int32) -> Bool
}

struct DarwinProcessSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        Darwin.kill(pid, signal) == 0
    }

    func isAlive(_ pid: Int32) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}

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
    @Published private(set) var processLoadError: String?

    var enableNotifications: Bool = true

    private var pollingTask: Task<Void, Never>?
    private var pollInterval: TimeInterval = 10
    private var pollProcessList = false

    private let currentPID = ProcessInfo.processInfo.processIdentifier
    private let processInventory: any ProcessInventoryProviding
    private let processSignaler: any ProcessSignaling
    private let lifecycle: any ProcessLifecycleServicing
    private let settleAfterProcessChange: () async -> Void
    private var fullProcessInventory: [AppProcess] = []
    private var selectedIdentities: [Int32: ProcessIdentity] = [:]
    private var operationIsRunning = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        processInventory: any ProcessInventoryProviding = SystemProcessInventory(),
        processSignaler: any ProcessSignaling = DarwinProcessSignaler(),
        lifecycle: any ProcessLifecycleServicing = SystemProcessLifecycleService(),
        settleAfterProcessChange: @escaping () async -> Void = {
            await ProcessLifecycleController.settleAfterProcessChange()
        }
    ) {
        self.processInventory = processInventory
        self.processSignaler = processSignaler
        self.lifecycle = lifecycle
        self.settleAfterProcessChange = settleAfterProcessChange
    }

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
        guard pid != currentPID,
              let process = fullProcessInventory.first(where: { $0.pid == pid }) else {
            return
        }

        if selectedPids.contains(pid) {
            selectedPids.remove(pid)
            selectedIdentities.removeValue(forKey: pid)
        } else {
            selectedPids.insert(pid)
            selectedIdentities[pid] = process.identity
        }
    }

    func clearSelection() {
        selectedPids.removeAll()
        selectedIdentities.removeAll()
    }

    func select(_ visibleProcesses: [AppProcess]) {
        let selectable = visibleProcesses.filter { $0.pid != currentPID }
        selectedPids = Set(selectable.map(\.pid))
        selectedIdentities = Dictionary(
            uniqueKeysWithValues: selectable.map { ($0.pid, $0.identity) }
        )
    }

    func selectionSnapshot() -> [ProcessIdentity] {
        fullProcessInventory.compactMap { selectedIdentities[$0.pid] }
    }

    func batchTerminate(_ requestedIdentities: [ProcessIdentity], forceKill: Bool = false) async {
        guard !requestedIdentities.isEmpty else {
            message = "Nothing selected."
            return
        }

        await runAction {
            let currentResult = await processInventory.load(fetchExtendedStats: false)
            guard case .success(let currentProcesses) = currentResult else {
                message = "Could not verify selected processes."
                return
            }

            let currentByIdentity = Dictionary(
                uniqueKeysWithValues: currentProcesses.map { ($0.identity, $0) }
            )
            let verified = requestedIdentities.compactMap { currentByIdentity[$0] }
            let staleCount = requestedIdentities.count - verified.count
            guard !verified.isEmpty else {
                clearSelection()
                message = "Selection changed; \(staleCount) no longer matched. Nothing was stopped."
                await refreshAfterMutation()
                return
            }

            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            var accepted = 0
            for process in verified where process.pid != currentPID {
                if processSignaler.send(signal, to: process.pid) {
                    accepted += 1
                }
            }
            await settleAfterProcessChange()

            let stopped = verified.filter { !processSignaler.isAlive($0.pid) }.count
            clearSelection()
            if forceKill {
                message = "Force stopped \(stopped) of \(requestedIdentities.count) selected."
            } else if accepted == 0 {
                message = "Could not send stop to the selected processes."
            } else if stopped == verified.count, staleCount == 0 {
                message = "Stopped \(stopped) of \(requestedIdentities.count) selected."
            } else {
                let stillRunning = verified.count - stopped
                message = "Stop requested; \(stillRunning) still running, \(staleCount) no longer matched."
            }
            await refreshAfterMutation()
        }
    }

    func refreshWatchedStatus(showMessage: Bool = true) async {
        await runAction {
            switch await currentSnapshots() {
            case .success(let watched):
                apply(watched)
                processLoadError = nil
                if showMessage {
                    message = watched.aggregateDetail
                }
            case .failure(let error):
                processLoadError = error.localizedDescription
                if showMessage {
                    message = "Could not refresh watched status: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadProcessList(showMessage: Bool = true) async {
        await runAction {
            switch await processInventory.load(fetchExtendedStats: fetchExtendedStats) {
            case .success(let inventory):
                fullProcessInventory = inventory
                apply(snapshots(from: inventory))
                publishDisplayProcesses()
                hasLoadedProcessList = true
                processLoadError = nil
                if showMessage {
                    message = "Loaded \(processes.count) of \(inventory.count) processes."
                }
            case .failure(let error):
                processLoadError = error.localizedDescription
                if showMessage {
                    message = "Could not load processes: \(error.localizedDescription)"
                }
            }
        }
    }

    func openApp(_ preset: WatchedAppPreset) async {
        await runAction {
            guard lifecycle.appBundleExists(at: preset.appPath) else {
                message = "Could not open \(preset.displayName): app bundle is missing at \(preset.appPath)."
                return
            }

            let daemonResult = await lifecycle.ensureSystemLaunchDaemons(for: preset)
            guard daemonResult.succeeded else {
                message = "Could not open \(preset.displayName): \(daemonResult.failureSummary ?? "required service failed")."
                return
            }

            let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
            guard agentResult.succeeded else {
                message = "Could not open \(preset.displayName): \(agentResult.failureSummary ?? "required user job failed")."
                return
            }

            let beforeOpen = await currentSnapshot(for: preset)
            let didOpen: Bool
            if beforeOpen.isMainRunning {
                didOpen = true
            } else {
                didOpen = await lifecycle.openAppBundle(at: preset.appPath)
            }
            guard didOpen else {
                message = "Could not open \(preset.displayName)."
                return
            }

            let verified: Bool
            if beforeOpen.isMainRunning {
                verified = true
            } else {
                verified = await lifecycle.waitForProcessNamed(
                    preset.mainProcessName,
                    timeoutSeconds: 5
                )
            }
            await refreshAfterMutation()

            if verified || snapshot(for: preset).isMainRunning {
                let restored = daemonResult.didChangeState || agentResult.didChangeState
                message = restored
                    ? "Opened \(preset.displayName) after restoring required services."
                    : "Opened \(preset.displayName)."
            } else {
                message = "\(preset.displayName) was launched, but its main process could not be verified."
            }
        }
    }

    func quitMainApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            await lifecycle.terminateProcess(named: preset.mainProcessName, forceIfStillRunning: true)
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            if !agentResult.succeeded {
                message = "Quit \(preset.displayName), but relaunch jobs failed: \(agentResult.failureSummary ?? "unknown failure")."
            } else if !before.isMainRunning && !snapshot(for: preset).isMainRunning {
                message = "No \(preset.displayName) app found."
            } else if !snapshot(for: preset).isMainRunning {
                message = agentResult.didChangeState
                    ? "\(preset.displayName) quit and launch agents unloaded."
                    : "\(preset.displayName) quit."
            } else {
                message = "\(preset.displayName) may still run."
            }
        }
    }

    func quitHelpers(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            for name in preset.helperProcessNames {
                await lifecycle.terminateProcess(named: name, forceIfStillRunning: true)
            }
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if !agentResult.succeeded {
                message = "Helper stop was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
            } else if before.helpersRunning.isEmpty && nowHelpers.isEmpty {
                message = "No user helpers found."
            } else if nowHelpers.isEmpty {
                message = agentResult.didChangeState
                    ? "User helpers quit and launch agents unloaded."
                    : "User helpers quit."
            } else {
                message = "User helpers may still run."
            }
        }
    }

    func quitAllKillable(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            for name in preset.killableNames {
                await lifecycle.terminateProcess(named: name, forceIfStillRunning: true)
            }
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if !agentResult.succeeded {
                message = "Close was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
            } else if !before.hasAny && !nowSnap.hasAny {
                message = "No watched processes found."
            } else if nowSnap.isMainRunning {
                message = "\(preset.displayName) may still run."
            } else if !nowSnap.helpersRunning.isEmpty {
                message = "User helpers may still run."
            } else {
                message = agentResult.didChangeState
                    ? "\(preset.displayName) closed and launch agents unloaded."
                    : "\(preset.displayName) and helpers quit."
            }
        }
    }

    @discardableResult
    func terminate(_ process: AppProcess, forceKill: Bool = false) async -> ProcessActionResult {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return .rejected
        }

        var result: ProcessActionResult = .rejected
        await runAction {
            let verificationResult = await processInventory.load(fetchExtendedStats: false)
            guard case .success(let currentProcesses) = verificationResult,
                  currentProcesses.contains(where: { $0.identity == process.identity }) else {
                message = "\(process.name) is no longer the same running process."
                reconcileSelection(with: currentProcesses(from: verificationResult))
                result = .stale
                return
            }

            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            let accepted = processSignaler.send(signal, to: process.pid)
            await settleAfterProcessChange()

            if !accepted {
                message = "Could not send \(forceKill ? "force stop" : "stop") to \(process.name)."
                result = .rejected
            } else if !processSignaler.isAlive(process.pid) {
                message = forceKill ? "\(process.name) force stopped." : "\(process.name) stopped."
                result = .stopped
            } else if forceKill {
                message = "\(process.name) is still running after Force Stop."
                result = .requestedStillRunning
            } else {
                message = "Stop requested for \(process.name); it is still running."
                result = .requestedStillRunning
            }

            await refreshAfterMutation()
        }
        return result
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
        switch await processInventory.load(fetchExtendedStats: hasLoadedProcessList && fetchExtendedStats) {
        case .success(let inventory):
            apply(snapshots(from: inventory))
            processLoadError = nil
            if hasLoadedProcessList {
                fullProcessInventory = inventory
                publishDisplayProcesses()
            }
        case .failure(let error):
            processLoadError = error.localizedDescription
        }
    }

    private func currentProcesses(
        from result: Result<[AppProcess], ProcessInventoryError>
    ) -> [AppProcess] {
        guard case .success(let processes) = result else { return [] }
        return processes
    }

    private func snapshot(for preset: WatchedAppPreset) -> WatchedAppSnapshot {
        snapshots.first(where: { $0.preset.id == preset.id }) ?? WatchedAppSnapshot(preset: preset, runningNames: [])
    }

    private func currentSnapshots() async -> Result<[WatchedAppSnapshot], ProcessInventoryError> {
        switch await processInventory.load(fetchExtendedStats: false) {
        case .success(let inventory):
            return .success(snapshots(from: inventory))
        case .failure(let error):
            return .failure(error)
        }
    }

    private func currentSnapshot(for preset: WatchedAppPreset) async -> WatchedAppSnapshot {
        switch await processInventory.load(fetchExtendedStats: false) {
        case .success(let inventory):
            return snapshot(for: preset, inventory: inventory)
        case .failure:
            return snapshot(for: preset)
        }
    }

    private func snapshots(from inventory: [AppProcess]) -> [WatchedAppSnapshot] {
        let presets = watchedAppsProvider?() ?? []
        return presets.map { snapshot(for: $0, inventory: inventory) }
    }

    private func snapshot(
        for preset: WatchedAppPreset,
        inventory: [AppProcess]
    ) -> WatchedAppSnapshot {
        let runningProcessNames = Set(inventory.map(\.name))
        let runningNames = Set(preset.allProcessNames.filter { runningProcessNames.contains($0) })
        return WatchedAppSnapshot(preset: preset, runningNames: runningNames)
    }

    func applyCurrentDisplayLimit() {
        guard hasLoadedProcessList else { return }
        publishDisplayProcesses()
    }

    @Published var fetchExtendedStats: Bool = false

    private func publishDisplayProcesses() {
        var sorted = fullProcessInventory
        sorted.sort { lhs, rhs in
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
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
            case .pid:
                return lhs.pid < rhs.pid
            }
        }
        let limit = processListLimitProvider?() ?? 80
        processes = Array(sorted.prefix(max(0, limit)))
        reconcileSelection(with: fullProcessInventory)
    }

    private func resortProcesses() {
        guard hasLoadedProcessList else { return }
        publishDisplayProcesses()
    }

    private func reconcileSelection(with inventory: [AppProcess]) {
        let currentIdentities = Set(inventory.map(\.identity))
        selectedIdentities = selectedIdentities.filter { currentIdentities.contains($0.value) }
        selectedPids = Set(selectedIdentities.keys)
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
        await acquireOperationSlot()

        isWorking = true
        defer {
            isWorking = false
            releaseOperationSlot()
        }

        await operation()
    }

    private func acquireOperationSlot() async {
        if !operationIsRunning {
            operationIsRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationSlot() {
        if operationWaiters.isEmpty {
            operationIsRunning = false
        } else {
            let next = operationWaiters.removeFirst()
            next.resume()
        }
    }

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
}
