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
    var isWorking: Bool {
        operationGate.isWorking
    }

    var operationState: ProcessOperationState {
        operationGate.state
    }

    @Published var sortKey: ProcessSortKey = .cpu {
        didSet { resortProcesses() }
    }

    @Published private(set) var selectedPids: Set<Int32> = []
    @Published private(set) var processLoadError: String?
    @Published private(set) var lastSuccessfulInventoryAt: Date?
    @Published private(set) var lifecycleReport: LifecycleReport?
    @Published private(set) var batchActionReport: ProcessBatchActionReport?

    func dismissLifecycleReport() {
        lifecycleReport = nil
    }

    func dismissBatchActionReport() {
        batchActionReport = nil
    }

    var enableNotifications: Bool = true

    private var pollInterval: TimeInterval = 10
    private var pollProcessList = false

    private let currentPID: Int32
    private let processInventory: any ProcessInventoryProviding
    private let verificationInventory: any ProcessInventoryProviding
    private let processSignaler: any ProcessSignaling
    private let batchTerminator: ProcessBatchTerminator
    private let lifecycle: any ProcessLifecycleServicing
    private let detailReader: any ProcessDetailReading
    private let settleAfterProcessChange: () async -> Void
    private let pollingController: ProcessPollingController
    private let snapshotBuilder: WatchedSnapshotBuilder
    private let operationGate = ProcessOperationGate()
    private var operationGateCancellable: AnyCancellable?
    private var fullProcessInventory: [AppProcess] = []
    private var selectedIdentities: [Int32: ProcessIdentity] = [:]
    private var extendedMetricsConsumers = 0
    private let now: () -> Date

    init(
        processInventory: any ProcessInventoryProviding = SystemProcessInventory(),
        verificationInventory: (any ProcessInventoryProviding)? = nil,
        processSignaler: any ProcessSignaling = DarwinProcessSignaler(),
        lifecycle: any ProcessLifecycleServicing = SystemProcessLifecycleService(),
        settleAfterProcessChange: @escaping () async -> Void = {
            await ProcessLifecycleController.settleAfterProcessChange()
        },
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        pollingController: ProcessPollingController? = nil,
        detailReader: any ProcessDetailReading = SystemProcessDetailReader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.currentPID = currentPID
        self.processInventory = processInventory
        self.verificationInventory = verificationInventory ?? processInventory
        self.processSignaler = processSignaler
        batchTerminator = ProcessBatchTerminator(
            inventory: verificationInventory ?? processInventory,
            signaler: processSignaler,
            settleAfterProcessChange: settleAfterProcessChange,
            currentPID: currentPID
        )
        self.lifecycle = lifecycle
        self.detailReader = detailReader
        self.settleAfterProcessChange = settleAfterProcessChange
        self.pollingController = pollingController ?? ProcessPollingController()
        self.now = now
        snapshotBuilder = WatchedSnapshotBuilder(excludedPID: currentPID)
        operationGateCancellable = operationGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func setPolling(interval: TimeInterval, includeProcessList: Bool) {
        pollInterval = max(2, interval)
        pollProcessList = includeProcessList
        restartPolling()
    }

    func restartPolling() {
        pollInterval = max(2, pollInterval)
        let interval = pollInterval
        let includeList = pollProcessList
        pollingController.restart(interval: interval) { [weak self] in
            guard let self else { return }
            await self.refreshWatchedStatus(showMessage: false)
            await self.enforceKeptOffPresets()
            if includeList, self.hasLoadedProcessList {
                await self.loadProcessList(showMessage: false)
            }
        }
    }

    func stopPolling() {
        pollingController.stop()
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
            let outcome = await batchTerminator.terminate(
                requestedIdentities,
                forceKill: forceKill
            )
            processLoadError = outcome.inventoryError
            message = outcome.message
            batchActionReport = outcome.report
            if outcome.shouldClearSelection {
                clearSelection()
            }
            if outcome.shouldRefresh {
                await refreshAfterMutation()
            }
        }
    }

    /// Callers do not need to say whether this refresh should re-baseline
    /// notifications; `apply` detects a changed watched-name set on its own.
    func refreshWatchedStatus(showMessage: Bool = true) async {
        await runAction(kind: .read(.watchedStatus)) {
            switch await currentSnapshots() {
            case .success(let watched):
                apply(watched)
            case .failure(let error):
                recordInventoryFailure(error)
            }
        }
        // An equivalent refresh may have been coalesced with a silent polling
        // refresh. Publish the explicit caller's message after the joined read has
        // completed so automation never returns a stale status string.
        if showMessage {
            if let processLoadError {
                message = "Could not refresh watched status: \(processLoadError)"
            } else {
                message = snapshots.aggregateDetail
            }
        }
    }

    func loadProcessList(showMessage: Bool = true) async {
        await runAction(kind: .read(.processList)) {
            switch await processInventory.load(fetchExtendedStats: fetchExtendedStats) {
            case .success(let inventory):
                recordInventorySuccess(clearsProcessLoadError: true)
                fullProcessInventory = inventory
                apply(snapshots(from: inventory))
                publishDisplayProcesses()
                hasLoadedProcessList = true
                if showMessage {
                    message = "Loaded \(processes.count) of \(inventory.count) processes."
                }
            case .failure(let error):
                recordInventoryFailure(error)
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

            guard case .success(let beforeOpen) = await currentSnapshot(for: preset) else {
                message = "Could not verify whether \(preset.displayName) is already running; nothing was opened."
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

            let wasKeptOff = isPresetKeptOffProvider?(preset) ?? false
            let enableResult: LifecycleBatchResult
            if wasKeptOff {
                enableResult = await lifecycle.enableUserLaunchAgents(for: preset)
                guard enableResult.succeeded else {
                    lifecycleReport = LifecycleReport(
                        title: "\(preset.displayName) Service Results",
                        jobs: daemonResult.jobs + enableResult.jobs
                    )
                    message = "Could not allow \(preset.displayName) to run: \(enableResult.failureSummary ?? "user launch agent could not be enabled")."
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
                setPresetKeptOffHandler?(preset, false)
            } else {
                enableResult = .notNeeded
            }

            let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
            guard agentResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs + enableResult.jobs + agentResult.jobs
                )
                message = "Could not open \(preset.displayName): \(agentResult.failureSummary ?? "required user job failed")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let serviceJobs = daemonResult.jobs + enableResult.jobs + agentResult.jobs
            lifecycleReport = serviceJobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: serviceJobs
                )

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
                verified = await lifecycle.waitForMainProcess(
                    for: preset,
                    timeoutSeconds: 5
                )
            }
            let refreshed = await refreshAfterMutation()

            if !refreshed {
                message = "\(preset.displayName) was launched, but TaskScope could not verify its final state."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if verified || snapshot(for: preset).isMainRunning {
                let restored = daemonResult.didChangeState
                    || enableResult.didChangeState
                    || agentResult.didChangeState
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

    /// Persists the user's intent and disables the preset's per-user launch jobs
    /// before stopping its ordinary app/helper processes. Protected system daemons
    /// are never signalled or disabled by this path.
    @discardableResult
    func keepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool = true
    ) async -> TaskScopeCommandResult {
        if recordIntent {
            setPresetKeptOffHandler?(preset, true)
        }

        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Keep Off did not complete."
        )
        await runAction(kind: .mutation) {
            let inventoryWasAvailable: Bool
            switch await currentSnapshot(for: preset) {
            case .success:
                inventoryWasAvailable = true
            case .failure:
                inventoryWasAvailable = false
            }
            let disableResult = await lifecycle.disableUserLaunchAgents(for: preset)
            lifecycleReport = disableResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Keep Off",
                    jobs: disableResult.jobs
                )

            guard inventoryWasAvailable else {
                message = disableResult.succeeded
                    ? "Keep Off disabled relaunch jobs, but the process list was unavailable; running processes were not signalled and enforcement will retry."
                    : "Keep Off remains enabled, but TaskScope could neither verify processes nor disable relaunch jobs."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            var terminationOutcomes: [ProcessTerminationOutcome] = []
            for (index, name) in preset.killableNames.enumerated() {
                let outcome = index == 0
                    ? await lifecycle.terminateMainProcess(for: preset)
                    : await lifecycle.terminateHelperProcess(named: name, for: preset)
                terminationOutcomes.append(outcome)
            }
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()
            let nowSnapshot = snapshot(for: preset)

            if !disableResult.succeeded {
                message = "Keep Off is enabled, but launch-agent suppression failed: \(disableResult.failureSummary ?? "unknown failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.inventoryUnavailable) {
                message = "Keep Off disabled relaunch jobs, but the process list became unavailable before app processes could be stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.signalRejected) {
                message = "Keep Off disabled relaunch jobs, but a running process rejected the stop signal."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.escalationUnavailable) || !refreshed {
                message = "Keep Off is enabled, but TaskScope could not verify the final process state."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if nowSnapshot.isMainRunning || nowSnapshot.hasHelpers {
                message = "Keep Off is enabled, but user-facing GlobalProtect processes may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else {
                message = nowSnapshot.protectedRunning.isEmpty
                    ? "\(preset.displayName) is kept off. Its user launch agents are disabled."
                    : "\(preset.displayName) app is kept off. Protected system service remains available."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            }
        }
        return commandResult
    }

    /// Clears persistent user-agent suppression without launching the app. This
    /// makes the toggle reversible while leaving explicit Open as the only action
    /// that starts GlobalProtect through TaskScope.
    @discardableResult
    func allowToRun(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Could not allow \(preset.displayName) to run."
        )
        await runAction(kind: .mutation) {
            let enableResult = await lifecycle.enableUserLaunchAgents(for: preset)
            lifecycleReport = enableResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Keep Off",
                    jobs: enableResult.jobs
                )
            guard enableResult.succeeded else {
                message = "Keep Off remains enabled: \(enableResult.failureSummary ?? "user launch agent could not be enabled")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            setPresetKeptOffHandler?(preset, false)
            message = "\(preset.displayName) is allowed to run. Nothing was started."
            commandResult = TaskScopeCommandResult(status: .completed, message: message)
        }
        return commandResult
    }

    /// Enforces persisted Keep Off intent after startup and if a user-facing job
    /// is restored externally. Routine polling skips work once only a protected
    /// system service (or nothing) remains.
    func enforceKeptOffPresets(force: Bool = false) async {
        for preset in keptOffPresetsProvider?() ?? [] {
            let current = snapshot(for: preset)
            guard force || current.isMainRunning || current.hasHelpers else { continue }
            _ = await keepOff(preset, recordIntent: false)
        }
    }

    @discardableResult
    func quitMainApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Quit did not complete."
        )
        await runAction(kind: .mutation) {
            guard case .success(let before) = await currentSnapshot(for: preset) else {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            let termination = await lifecycle.terminateMainProcess(for: preset)
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()

            if termination == .inventoryUnavailable {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if termination == .signalRejected {
                message = "A stop signal was rejected; \(preset.displayName) was not fully stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if termination == .escalationUnavailable {
                message = "Could not verify \(preset.displayName) before Force Stop; it may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Quit \(preset.displayName), but relaunch jobs failed: \(agentResult.failureSummary ?? "unknown failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !refreshed {
                message = "Stop was requested, but TaskScope could not verify the final \(preset.displayName) state."
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
            guard case .success(let before) = await currentSnapshot(for: preset) else {
                message = "Could not read the process list; user helpers were not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            var terminationOutcomes: [ProcessTerminationOutcome] = []
            for name in preset.helperProcessNames {
                let outcome = await lifecycle.terminateHelperProcess(named: name, for: preset)
                terminationOutcomes.append(outcome)
            }
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if terminationOutcomes.contains(.inventoryUnavailable) {
                message = "Could not read the process list; user helpers were not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.signalRejected) {
                message = "A stop signal was rejected; user helpers were not fully stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.escalationUnavailable) {
                message = "Could not verify user helpers before Force Stop; they may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Helper stop was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !refreshed {
                message = "Helper stop was requested, but TaskScope could not verify the final state."
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
            guard case .success(let before) = await currentSnapshot(for: preset) else {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let agentResult = await lifecycle.unloadUserLaunchAgents(for: preset)
            lifecycleReport = agentResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Relaunch Jobs",
                    jobs: agentResult.jobs
                )
            var terminationOutcomes: [ProcessTerminationOutcome] = []
            for (index, name) in preset.killableNames.enumerated() {
                let outcome = index == 0
                    ? await lifecycle.terminateMainProcess(for: preset)
                    : await lifecycle.terminateHelperProcess(named: name, for: preset)
                terminationOutcomes.append(outcome)
            }
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if terminationOutcomes.contains(.inventoryUnavailable) {
                message = "Could not read the process list; \(preset.displayName) was not stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.signalRejected) {
                message = "A stop signal was rejected; \(preset.displayName) was not fully stopped."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.escalationUnavailable) {
                message = "Could not verify \(preset.displayName) before Force Stop; it may still run."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !agentResult.succeeded {
                message = "Close was incomplete: \(agentResult.failureSummary ?? "relaunch job failure")."
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if !refreshed {
                message = "Close was requested, but TaskScope could not verify the final \(preset.displayName) state."
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
    func terminate(
        _ process: AppProcess,
        forceKill: Bool = false,
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async -> ProcessActionResult {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return .rejected
        }

        var result: ProcessActionResult = .rejected
        await runAction(kind: .mutation) {
            let verificationResult = await verificationInventory.load(fetchExtendedStats: false)
            // An unreadable process list says nothing about this target. Treating it
            // as an identity change both lied to the user and wiped the whole
            // selection by reconciling against an empty inventory.
            guard case .success(let currentProcesses) = verificationResult else {
                if case .failure(let error) = verificationResult {
                    recordInventoryFailure(error)
                }
                message = "Could not verify \(process.name); nothing was stopped."
                result = .rejected
                return
            }
            recordInventorySuccess()
            guard currentProcesses.contains(where: { $0.identity == process.identity }) else {
                message = "\(process.name) is no longer the same running process."
                reconcileSelection(with: currentProcesses)
                result = .stale
                return
            }

            // Auto-stop rules can be disabled or deleted while this mutation is
            // queued or while identity verification is suspended. This is the
            // final authority check: no await may occur between it and kill(2).
            guard !Task.isCancelled, isAuthorized() else {
                message = "Stop for \(process.name) was cancelled."
                result = .rejected
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
        await detailReader.readDetail(for: process)
    }

    func isCurrentProcess(_ process: AppProcess) -> Bool {
        process.pid == currentPID
    }

    var ppidMap: [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for p in fullProcessInventory { map[p.pid] = p.parentPID }
        return map
    }

    @discardableResult
    private func refreshAfterMutation() async -> Bool {
        switch await verificationInventory.load(fetchExtendedStats: hasLoadedProcessList && fetchExtendedStats) {
        case .success(let inventory):
            recordInventorySuccess(clearsProcessLoadError: hasLoadedProcessList)
            apply(snapshots(from: inventory))
            if hasLoadedProcessList {
                fullProcessInventory = inventory
                publishDisplayProcesses()
            }
            return true
        case .failure(let error):
            recordInventoryFailure(error)
            return false
        }
    }

    private func snapshot(for preset: WatchedAppPreset) -> WatchedAppSnapshot {
        snapshots.first(where: { $0.preset.id == preset.id }) ?? WatchedAppSnapshot(preset: preset, runningNames: [])
    }

    private func currentSnapshots() async -> Result<[WatchedAppSnapshot], ProcessInventoryError> {
        switch await processInventory.load(fetchExtendedStats: false) {
        case .success(let inventory):
            recordInventorySuccess()
            return .success(snapshots(from: inventory))
        case .failure(let error):
            recordInventoryFailure(error)
            return .failure(error)
        }
    }

    private func currentSnapshot(
        for preset: WatchedAppPreset
    ) async -> Result<WatchedAppSnapshot, ProcessInventoryError> {
        switch await verificationInventory.load(fetchExtendedStats: false) {
        case .success(let inventory):
            recordInventorySuccess()
            return .success(snapshot(for: preset, inventory: inventory))
        case .failure(let error):
            recordInventoryFailure(error)
            return .failure(error)
        }
    }

    private func recordInventorySuccess(clearsProcessLoadError: Bool = false) {
        if clearsProcessLoadError {
            processLoadError = nil
        }
        lastSuccessfulInventoryAt = now()
    }

    private func recordInventoryFailure(_ error: ProcessInventoryError) {
        processLoadError = error.localizedDescription
    }

    private func snapshots(from inventory: [AppProcess]) -> [WatchedAppSnapshot] {
        let presets = watchedAppsProvider?() ?? []
        return snapshotBuilder.snapshots(for: presets, in: inventory)
    }

    private func snapshot(
        for preset: WatchedAppPreset,
        inventory: [AppProcess]
    ) -> WatchedAppSnapshot {
        snapshotBuilder.snapshot(for: preset, in: inventory)
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

    /// The set of process names the baseline is allowed to be diffed against.
    /// Changing it — adding or removing a preset, editing its process names, or
    /// toggling its notification switch — invalidates the baseline.
    private func notifiableWatchedNames(in watched: [WatchedAppSnapshot]) -> Set<String> {
        Set(watched.filter { $0.preset.notificationsEnabled }.flatMap { $0.preset.allProcessNames })
    }

    private func apply(_ watched: [WatchedAppSnapshot]) {
        let previousWatchedNames = notifiableWatchedNames(in: snapshots)
        snapshots = watched
        status = watched.aggregateStatus

        guard enableNotifications else { return }

        // Decide here rather than at the call site. A diff is only meaningful when
        // the watched-name universe is unchanged; if it changed, the baseline
        // predates these presets and diffing would report an already-running app as
        // newly started. Self-detecting removes any dependence on callers passing
        // the right flag, and on the order in which they run.
        let names = notifiableRunningNames(in: watched)
        if previousWatchedNames == notifiableWatchedNames(in: watched) {
            notifyTransitions(names)
        } else {
            primeNotificationBaseline(names)
        }
    }

    @discardableResult
    private func runAction(
        kind: ProcessOperationGate.Kind,
        _ operation: () async -> Void
    ) async -> Bool {
        await operationGate.run(kind: kind, operation)
    }

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
    var keptOffPresetsProvider: (() -> [WatchedAppPreset])?
    var isPresetKeptOffProvider: ((WatchedAppPreset) -> Bool)?
    var setPresetKeptOffHandler: ((WatchedAppPreset, Bool) -> Void)?
}
