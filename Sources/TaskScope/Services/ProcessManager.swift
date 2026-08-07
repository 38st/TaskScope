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
    @Published private(set) var operationState: ProcessOperationState = .idle

    @Published var sortKey: ProcessSortKey = .cpu {
        didSet { resortProcesses() }
    }

    @Published private(set) var selectedPids: Set<Int32> = []
    @Published private(set) var processLoadError: String?
    @Published private(set) var lifecycleReport: LifecycleReport?
    @Published private(set) var batchActionReport: ProcessBatchActionReport?

    func dismissLifecycleReport() {
        lifecycleReport = nil
    }

    func dismissBatchActionReport() {
        batchActionReport = nil
    }

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
    private enum ReadOperation: Equatable {
        case watchedStatus
        case processList
    }

    private enum OperationKind: Equatable {
        case read(ReadOperation)
        case mutation

        var isMutation: Bool {
            self == .mutation
        }
    }

    private struct OperationWaiter {
        var id: UUID
        var kind: OperationKind
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var activeOperation: OperationKind?
    private var operationWaiters: [OperationWaiter] = []
    private var extendedMetricsConsumers = 0

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

    func restrictSelection(to visibleProcesses: [AppProcess]) {
        let visibleIdentities = Set(visibleProcesses.map(\.identity))
        selectedIdentities = selectedIdentities.filter { visibleIdentities.contains($0.value) }
        selectedPids = Set(selectedIdentities.keys)
    }

    func selectionSnapshot() -> [ProcessIdentity] {
        fullProcessInventory.compactMap { selectedIdentities[$0.pid] }
    }

    var inventorySnapshot: [AppProcess] {
        fullProcessInventory
    }

    func displayProcesses(
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        let limit = processListLimitProvider?() ?? 80
        return Array(
            sorted(fullProcessInventory)
                .lazy
                .filter(predicate)
                .prefix(max(0, limit))
        )
    }

    func selectedProcessesSnapshot() -> [AppProcess] {
        fullProcessInventory.filter { selectedIdentities[$0.pid] == $0.identity }
    }

    func batchTerminate(_ requestedIdentities: [ProcessIdentity], forceKill: Bool = false) async {
        guard !requestedIdentities.isEmpty else {
            message = "Nothing selected."
            return
        }

        await runAction(kind: .mutation) {
            let currentResult = await processInventory.load(fetchExtendedStats: false)
            guard case .success(let currentProcesses) = currentResult else {
                if case .failure(let error) = currentResult {
                    processLoadError = error.localizedDescription
                }
                message = "Could not verify selected processes."
                batchActionReport = ProcessBatchActionReport(
                    title: forceKill ? "Force Stop Results" : "Stop Results",
                    targets: requestedIdentities.map {
                        ProcessTargetActionResult(
                            identity: $0,
                            name: $0.command.isEmpty ? "PID \($0.pid)" : URL(fileURLWithPath: $0.command).lastPathComponent,
                            // Nothing was checked, so we cannot claim these are gone.
                            state: .unverified
                        )
                    }
                )
                return
            }

            let currentByIdentity = Dictionary(
                uniqueKeysWithValues: currentProcesses.map { ($0.identity, $0) }
            )
            let verified = requestedIdentities.compactMap { currentByIdentity[$0] }
            var targetResults = requestedIdentities.compactMap { identity -> ProcessTargetActionResult? in
                guard currentByIdentity[identity] == nil else { return nil }
                return ProcessTargetActionResult(
                    identity: identity,
                    name: identity.command.isEmpty
                        ? "PID \(identity.pid)"
                        : URL(fileURLWithPath: identity.command).lastPathComponent,
                    state: .stale
                )
            }
            let staleCount = targetResults.count
            guard !verified.isEmpty else {
                clearSelection()
                message = "Selection changed; \(staleCount) no longer matched. Nothing was stopped."
                batchActionReport = ProcessBatchActionReport(
                    title: forceKill ? "Force Stop Results" : "Stop Results",
                    targets: targetResults
                )
                await refreshAfterMutation()
                return
            }

            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            var acceptedIdentities: Set<ProcessIdentity> = []
            for process in verified where process.pid != currentPID {
                guard processSignaler.send(signal, to: process.pid) else {
                    targetResults.append(ProcessTargetActionResult(
                        identity: process.identity,
                        name: process.name,
                        state: .signalRejected
                    ))
                    continue
                }
                acceptedIdentities.insert(process.identity)
            }
            await settleAfterProcessChange()

            for process in verified where acceptedIdentities.contains(process.identity) {
                targetResults.append(ProcessTargetActionResult(
                    identity: process.identity,
                    name: process.name,
                    state: processSignaler.isAlive(process.pid)
                        ? .requestedStillRunning
                        : .stopped
                ))
            }
            targetResults.sort { lhs, rhs in
                let lhsIndex = requestedIdentities.firstIndex(of: lhs.identity) ?? Int.max
                let rhsIndex = requestedIdentities.firstIndex(of: rhs.identity) ?? Int.max
                return lhsIndex < rhsIndex
            }
            batchActionReport = ProcessBatchActionReport(
                title: forceKill ? "Force Stop Results" : "Stop Results",
                targets: targetResults
            )

            let accepted = acceptedIdentities.count
            let stopped = targetResults.filter { $0.state == .stopped }.count
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

    /// - Parameter rebaselineNotifications: refresh without emitting start/stop
    ///   notifications, then re-baseline from the freshly computed snapshots. Used
    ///   when the preset list changes: the old baseline has no entry for a preset
    ///   that did not exist yet, so an already-running app would otherwise be
    ///   reported as having just started.
    func refreshWatchedStatus(
        showMessage: Bool = true,
        rebaselineNotifications: Bool = false
    ) async {
        await runAction(kind: .read(.watchedStatus)) {
            switch await currentSnapshots() {
            case .success(let watched):
                apply(watched, suppressNotifications: rebaselineNotifications)
                if rebaselineNotifications {
                    primeNotificationBaseline(notifiableRunningNames(in: watched))
                }
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
        await runAction(kind: .read(.processList)) {
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

    @discardableResult
    func openApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Open did not complete."
        )
        await runAction(kind: .mutation) {
            guard lifecycle.appBundleExists(at: preset.appPath) else {
                message = "Could not open \(preset.displayName): app bundle is missing at \(preset.appPath)."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let daemonResult = await lifecycle.ensureSystemLaunchDaemons(for: preset)
            guard daemonResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs
                )
                message = "Could not open \(preset.displayName): \(daemonResult.failureSummary ?? "required service failed")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
            guard agentResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs + agentResult.jobs
                )
                message = "Could not open \(preset.displayName): \(agentResult.failureSummary ?? "required user job failed")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let serviceJobs = daemonResult.jobs + agentResult.jobs
            lifecycleReport = serviceJobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: serviceJobs
                )

            let beforeOpen = await currentSnapshot(for: preset)
            let didOpen: Bool
            if beforeOpen.isMainRunning {
                didOpen = true
            } else {
                didOpen = await lifecycle.openAppBundle(at: preset.appPath)
            }
            guard didOpen else {
                message = "Could not open \(preset.displayName)."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
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
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else {
                message = "\(preset.displayName) was launched, but its main process could not be verified."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            }
        }
        return commandResult
    }

    @discardableResult
    func quitMainApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Quit did not complete."
        )
        await runAction(kind: .mutation) {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            let termination = await lifecycle.terminateProcess(
                named: preset.mainProcessName,
                forceIfStillRunning: true
            )
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            if termination == .inventoryUnavailable {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Quit \(preset.displayName), but relaunch jobs failed: \(agentResult.failureSummary ?? "unknown failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !before.isMainRunning && !snapshot(for: preset).isMainRunning {
                message = "No \(preset.displayName) app found."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else if !snapshot(for: preset).isMainRunning {
                message = agentResult.didChangeState
                    ? "\(preset.displayName) quit and launch agents unloaded."
                    : "\(preset.displayName) quit."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else {
                message = "\(preset.displayName) may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            }
        }
        return commandResult
    }

    @discardableResult
    func quitHelpers(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Helper stop did not complete."
        )
        await runAction(kind: .mutation) {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            var terminationBlocked = false
            for name in preset.helperProcessNames {
                let outcome = await lifecycle.terminateProcess(named: name, forceIfStillRunning: true)
                terminationBlocked = terminationBlocked || outcome == .inventoryUnavailable
            }
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if terminationBlocked {
                message = "Could not read the process list; user helpers were not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Helper stop was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if before.helpersRunning.isEmpty && nowHelpers.isEmpty {
                message = "No user helpers found."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else if nowHelpers.isEmpty {
                message = agentResult.didChangeState
                    ? "User helpers quit and launch agents unloaded."
                    : "User helpers quit."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else {
                message = "User helpers may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            }
        }
        return commandResult
    }

    @discardableResult
    func quitAllKillable(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Close did not complete."
        )
        await runAction(kind: .mutation) {
            let before = await currentSnapshot(for: preset)
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            var terminationBlocked = false
            for name in preset.killableNames {
                let outcome = await lifecycle.terminateProcess(named: name, forceIfStillRunning: true)
                terminationBlocked = terminationBlocked || outcome == .inventoryUnavailable
            }
            await lifecycle.settleAfterProcessChange()
            await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if terminationBlocked {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Close was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !before.hasAny && !nowSnap.hasAny {
                message = "No watched processes found."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else if nowSnap.isMainRunning {
                message = "\(preset.displayName) may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !nowSnap.helpersRunning.isEmpty {
                message = "User helpers may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else {
                message = agentResult.didChangeState
                    ? "\(preset.displayName) closed and launch agents unloaded."
                    : "\(preset.displayName) and helpers quit."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            }
        }
        return commandResult
    }

    @discardableResult
    func terminate(_ process: AppProcess, forceKill: Bool = false) async -> ProcessActionResult {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return .rejected
        }

        var result: ProcessActionResult = .rejected
        await runAction(kind: .mutation) {
            let verificationResult = await processInventory.load(fetchExtendedStats: false)
            // An unreadable process list says nothing about this target. Treating it
            // as an identity change both lied to the user and wiped the whole
            // selection by reconciling against an empty inventory.
            guard case .success(let currentProcesses) = verificationResult else {
                if case .failure(let error) = verificationResult {
                    processLoadError = error.localizedDescription
                }
                message = "Could not verify \(process.name); nothing was stopped."
                result = .rejected
                return
            }
            guard currentProcesses.contains(where: { $0.identity == process.identity }) else {
                message = "\(process.name) is no longer the same running process."
                reconcileSelection(with: currentProcesses)
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

        // The PID resolving is not enough: if the row's process exited and the PID
        // was recycled, this read belongs to a different process. `startTime` comes
        // from `ps lstart` on both sides, so it is directly comparable. (`command`
        // is not: the inventory uses `ps -c` and gets a short name.)
        guard startTime == process.identity.startTime else { return nil }

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
        for p in fullProcessInventory { map[p.pid] = p.parentPID }
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

    @Published private(set) var fetchExtendedStats: Bool = false

    func beginExtendedMetrics() async {
        extendedMetricsConsumers += 1
        guard extendedMetricsConsumers == 1 else { return }
        fetchExtendedStats = true
        if hasLoadedProcessList {
            await loadProcessList(showMessage: false)
        }
    }

    func endExtendedMetrics() {
        // Deliberately not clamped at zero. `beginExtendedMetrics` is async, so a
        // consumer's release can land before its own acquire; clamping swallowed the
        // early release and the late acquire then latched collection on with no
        // consumer left to turn it off — an un-stoppable nettop/ps fork per poll for
        // the life of the process. Letting the count go negative lets the late
        // acquire cancel out instead, which fails closed rather than open.
        extendedMetricsConsumers -= 1
        if extendedMetricsConsumers <= 0 {
            fetchExtendedStats = false
        }
    }

    private func publishDisplayProcesses() {
        processes = displayProcesses()
        reconcileSelection(with: processes)
    }

    private func sorted(_ inventory: [AppProcess]) -> [AppProcess] {
        inventory.sorted { lhs, rhs in
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

    func notifiableRunningNames(in watched: [WatchedAppSnapshot]) -> Set<String> {
        Set(watched.filter { $0.preset.notificationsEnabled }.flatMap { $0.runningNames })
    }

    /// Seams over the notification singleton so the baseline/diff ordering is
    /// testable; both default to `NotificationService.shared`.
    var notifyTransitions: (Set<String>) -> Void = {
        NotificationService.shared.diffAndNotify(currentRunningNames: $0)
    }
    var primeNotificationBaseline: (Set<String>) -> Void = {
        NotificationService.shared.prime(initialRunningNames: $0)
    }

    private func apply(_ watched: [WatchedAppSnapshot], suppressNotifications: Bool = false) {
        snapshots = watched
        status = watched.aggregateStatus

        if enableNotifications, !suppressNotifications {
            notifyTransitions(notifiableRunningNames(in: watched))
        }
    }

    @discardableResult
    private func runAction(
        kind: OperationKind,
        _ operation: () async -> Void
    ) async -> Bool {
        guard await acquireOperationSlot(for: kind) else {
            if !Task.isCancelled {
                operationState = .coalesced
            }
            return false
        }
        guard !Task.isCancelled else {
            releaseOperationSlot()
            return false
        }

        isWorking = true
        operationState = kind.isMutation ? .runningMutation : .runningRefresh
        defer {
            isWorking = false
            releaseOperationSlot()
        }

        await operation()
        return true
    }

    private func acquireOperationSlot(for kind: OperationKind) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeOperation == nil {
            activeOperation = kind
            return true
        }

        if case .read(let requestedRead) = kind {
            let activeMatches = activeOperation == .read(requestedRead)
            let queuedMatches = operationWaiters.contains { $0.kind == .read(requestedRead) }
            if activeMatches || queuedMatches {
                return false
            }
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                operationWaiters.append(
                    OperationWaiter(
                        id: waiterID,
                        kind: kind,
                        continuation: continuation
                    )
                )
                operationState = .queued
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelOperationWaiter(id: waiterID)
            }
        }
    }

    private func cancelOperationWaiter(id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        if operationWaiters.isEmpty, let activeOperation {
            operationState = activeOperation.isMutation
                ? .runningMutation
                : .runningRefresh
        }
    }

    private func releaseOperationSlot() {
        if operationWaiters.isEmpty {
            activeOperation = nil
            operationState = .idle
        } else {
            let nextIndex = operationWaiters.firstIndex { $0.kind.isMutation } ?? 0
            let next = operationWaiters.remove(at: nextIndex)
            activeOperation = next.kind
            next.continuation.resume(returning: true)
        }
    }

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
}
