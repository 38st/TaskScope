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
    /// Increments whenever the full inventory changes. Views key derived,
    /// memoized lists on it.
    @Published private(set) var inventoryGeneration: UInt64 = 0
    @Published private(set) var processLoadError: String?
    @Published private(set) var lastSuccessfulInventoryAt: Date?
    @Published private(set) var lifecycleReport: LifecycleReport?
    /// One explicit failed disconnect may be followed by a separately confirmed
    /// service stop. Never persisted, exposed to URLs, or used by polling.
    @Published private(set) var globalProtectDisconnectFailureID: UUID?
    @Published private(set) var batchActionReport: ProcessBatchActionReport?
    private(set) var lifecycleDiagnostics = LifecycleDiagnosticsHistory()

    func clearLifecycleDiagnostics() {
        lifecycleDiagnostics.clear()
    }

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
    private var listProjection = ProcessListProjection()
    private var fullProcessInventory: [AppProcess] {
        get { listProjection.inventory }
        set {
            listProjection = ProcessListProjection(inventory: newValue)
            inventoryGeneration &+= 1
        }
    }
    private var selectedIdentities: [Int32: ProcessIdentity] = [:]
    private var extendedMetricsConsumers = 0
    private let now: () -> Date
    private var successfulInventoryReads: UInt64 = 0
    private var lastInventoryFailure: String?

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
            selectable.map { ($0.pid, $0.identity) },
            uniquingKeysWith: { first, _ in first }
        )
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
        listProjection.displayProcesses(
            sortKey: sortKey,
            limit: processListLimitProvider?() ?? 80,
            matching: predicate
        )
    }

    /// The sorted, filtered, limited list for `query`, memoized per inventory,
    /// sort key, and limit by the projection.
    func displayProcesses(for query: ProcessListQuery) -> [AppProcess] {
        listProjection.displayProcesses(
            for: query, sortKey: sortKey, limit: processListLimitProvider?() ?? 80
        )
    }

    /// Tree roots give every displayed match its ancestor context from the full
    /// inventory, including ancestors outside the display limit.
    func treeRoots(for query: ProcessListQuery) -> [ProcessTreeNode] {
        listProjection.treeRoots(
            for: query, sortKey: sortKey, limit: processListLimitProvider?() ?? 80
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
    /// Returns whether a fresh inventory was applied by this call (or by the
    /// equivalent read it joined).
    @discardableResult
    func refreshWatchedStatus(showMessage: Bool = true) async -> Bool {
        let readsBefore = successfulInventoryReads
        await runAction(kind: .read(.watchedStatus)) {
            switch await currentSnapshots() {
            case .success(let watched):
                apply(watched)
            case .failure(let error):
                recordInventoryFailure(error)
            }
        }
        let refreshed = successfulInventoryReads != readsBefore
        // An equivalent refresh may have been coalesced with a silent polling
        // refresh. Publish the explicit caller's message after the joined read has
        // completed so automation never returns a stale status string.
        if showMessage {
            if refreshed {
                message = snapshots.aggregateDetail
            } else {
                message = "Could not refresh watched status: \(lastInventoryFailure ?? "the process list could not be read")"
            }
        }
        return refreshed
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
                let failure = Task.isCancelled ? ProcessInventoryError.cancelled : error
                recordInventoryFailure(failure)
                if showMessage, failure != .cancelled {
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
            if preset.hasCanonicalGlobalProtectIdentity { globalProtectDisconnectFailureID = nil }
            var diagnosticReason: LifecycleDiagnosticFailure.Reason = .incomplete
            var diagnosticJobs: [LifecycleJobResult] = []
            defer {
                if commandResult.status == .failed {
                    lifecycleDiagnostics.record(
                        presetID: preset.id, action: .open,
                        backgroundEnforcement: false, reason: diagnosticReason,
                        jobs: diagnosticJobs, at: now()
                    )
                }
            }
            guard lifecycle.appBundleExists(at: preset.appPath) else {
                message = "Could not open \(preset.displayName): app bundle is missing at \(preset.appPath)."
                diagnosticReason = .appBundleMissing
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            guard case .success(let beforeServices) = await currentSnapshot(for: preset) else {
                message = "Could not verify whether \(preset.displayName) is already running; nothing was opened."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            // A UI started directly while PanGPS was stopped can remain stuck
            // retrieving configuration even after the service returns. Restart
            // that orphaned UI before restoration; never unload the VPN job.
            if preset.hasCanonicalGlobalProtectIdentity,
               beforeServices.isMainRunning,
               beforeServices.protectedRunning.isEmpty,
               beforeServices.unprivilegedProtectedRunning.isEmpty {
                var uiOnly = preset
                uiOnly.userLaunchAgentJobs = [WatchedAppPreset.globalProtectUserLaunchAgentJobs[0]]
                // Do not match the legacy built-in payload, which expands to
                // both user jobs through lifecycleUserLaunchAgentJobs.
                uiOnly.systemLaunchDaemonJobs = []
                let unloadedUI = await lifecycle.unloadUserLaunchAgents(for: uiOnly)
                diagnosticJobs += unloadedUI.jobs
                guard unloadedUI.succeeded else {
                    lifecycleReport = LifecycleReport(title: "GlobalProtect UI Recovery", jobs: unloadedUI.jobs)
                    message = "Could not close GlobalProtect's stalled interface. Its VPN service was not stopped."
                    diagnosticReason = .userLaunchAgentFailed
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
                let stoppedUI = await lifecycle.terminateMainProcess(for: preset)
                await lifecycle.settleAfterProcessChange()
                guard [.signalled, .noMatchingProcesses, .targetsExited].contains(stoppedUI),
                      case .success(let afterUIStop) = await currentSnapshot(for: preset),
                      !afterUIStop.isMainRunning else {
                    message = "Could not verify that GlobalProtect's stalled interface closed; no second instance was started."
                    diagnosticReason = .verificationUnavailable
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
            }

            let systemEnable = preset.hasCanonicalGlobalProtectIdentity
                ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
            diagnosticJobs += systemEnable.jobs
            guard systemEnable.succeeded else {
                lifecycleReport = LifecycleReport(title: "\(preset.displayName) Service Results", jobs: systemEnable.jobs)
                message = "Could not restore GlobalProtect: \(systemEnable.failureSummary ?? "system service could not be enabled")."
                diagnosticReason = .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let ensuredDaemon = await lifecycle.ensureSystemLaunchDaemons(for: preset)
            let daemonResult = LifecycleBatchResult(jobs: systemEnable.jobs + ensuredDaemon.jobs)
            diagnosticJobs += ensuredDaemon.jobs
            guard daemonResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs
                )
                message = "Could not open \(preset.displayName): \(daemonResult.failureSummary ?? "required service failed")."
                diagnosticReason = .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let wasKeptOff = isPresetKeptOffProvider?(preset) ?? false
            let enableResult: LifecycleBatchResult
            // launchd overrides outlive TaskScope preferences (including reset
            // or reinstall). Explicit Open must recover them even without intent.
            if wasKeptOff || preset.hasCanonicalGlobalProtectIdentity {
                enableResult = await lifecycle.enableUserLaunchAgents(for: preset)
                diagnosticJobs += enableResult.jobs
                guard enableResult.succeeded else {
                    lifecycleReport = LifecycleReport(
                        title: "\(preset.displayName) Service Results",
                        jobs: daemonResult.jobs + enableResult.jobs
                    )
                    message = "Could not allow \(preset.displayName) to run: \(enableResult.failureSummary ?? "user launch agent could not be enabled")."
                    diagnosticReason = .userLaunchAgentFailed
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
                setPresetKeptOffHandler?(preset, false)
            } else {
                enableResult = .notNeeded
            }

            let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
            diagnosticJobs += agentResult.jobs
            guard agentResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs + enableResult.jobs + agentResult.jobs
                )
                message = "Could not open \(preset.displayName): \(agentResult.failureSummary ?? "required user job failed")."
                diagnosticReason = .userLaunchAgentFailed
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

            // Restoring the user launch agents can itself start the main process
            // (GlobalProtect's `pangpa` agent runs the main binary). Re-check with
            // a fresh inventory before opening so a second instance is never
            // launched, and fail closed when that check cannot be made.
            guard case .success(let afterServices) = await currentSnapshot(for: preset) else {
                message = "Could not verify whether \(preset.displayName) started with its services; nothing was opened."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let alreadyRunning = afterServices.isMainRunning

            let didOpen: Bool
            if alreadyRunning {
                didOpen = true
            } else {
                didOpen = await lifecycle.openAppBundle(at: preset.appPath)
            }
            guard didOpen else {
                message = "Could not open \(preset.displayName)."
                diagnosticReason = .launchFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            if !alreadyRunning {
                _ = await lifecycle.waitForMainProcess(
                    for: preset,
                    timeoutSeconds: 5
                )
            }
            let finalInventory = await refreshInventoryAfterMutation()

            if finalInventory == nil {
                message = "\(preset.displayName) was launched, but TaskScope could not verify its final state."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if let finalInventory,
                      snapshot(for: preset, inventory: finalInventory).isMainRunning {
                let restored = daemonResult.didChangeState
                    || enableResult.didChangeState
                    || agentResult.didChangeState
                message = restored
                    ? "Opened \(preset.displayName) after restoring required services."
                    : "Opened \(preset.displayName)."
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else {
                message = "\(preset.displayName) was launched, but its main process could not be verified."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            }
        }
        return commandResult
    }

    /// Persists intent and disables user jobs. An explicit built-in GlobalProtect
    /// action also disables/unloads the fixed system service with authorization;
    /// background enforcement only verifies it and never requests privileges.
    ///
    /// With `recordIntent == false` this is background enforcement. It re-checks
    /// the persisted intent *inside* the operation gate: a poll tick that decided
    /// to enforce can be queued behind a user's Open, which clears the intent, and
    /// running the enforcement afterwards would re-disable the agents the user
    /// just restored and quit the app they just opened.
    @discardableResult
    func keepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool = true
    ) async -> TaskScopeCommandResult {
        await applyKeepOff(preset, recordIntent: recordIntent)
    }

    @discardableResult
    func stopGlobalProtectAfterFailedDisconnect(failureID: UUID) async -> TaskScopeCommandResult {
        await applyKeepOff(.globalProtect, recordIntent: true, confirmedFailureID: failureID)
    }

    private func applyKeepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool,
        confirmedFailureID: UUID? = nil
    ) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Keep Off did not complete."
        )
        await runAction(kind: .mutation) {
            if let confirmedFailureID {
                guard recordIntent, preset.hasCanonicalGlobalProtectIdentity,
                      confirmedFailureID == globalProtectDisconnectFailureID else {
                    commandResult = TaskScopeCommandResult(status: .rejected, message: "This disconnect failure is no longer current. Choose Keep GlobalProtect Off again.")
                    message = commandResult.message
                    return
                }
            }
            var diagnosticReason: LifecycleDiagnosticFailure.Reason = .incomplete
            var diagnosticJobs: [LifecycleJobResult] = []
            defer {
                if commandResult.status == .failed {
                    lifecycleDiagnostics.record(
                        presetID: preset.id, action: .keepOff,
                        backgroundEnforcement: !recordIntent, reason: diagnosticReason,
                        jobs: diagnosticJobs, at: now()
                    )
                }
            }
            if !recordIntent, isPresetKeptOffProvider?(preset) != true {
                commandResult = TaskScopeCommandResult(
                    status: .rejected,
                    message: "Keep Off is no longer enabled for \(preset.displayName); enforcement skipped."
                )
                return
            }

            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                globalProtectDisconnectFailureID = nil
                if confirmedFailureID == nil {
                    message = "Disconnecting GlobalProtect before stopping its services…"
                    if case .failed(let detail) = await lifecycle.disconnectGlobalProtectIfNeeded() {
                        globalProtectDisconnectFailureID = UUID()
                        message = detail
                        diagnosticReason = .disconnectFailed
                        commandResult = TaskScopeCommandResult(status: .failed, message: detail)
                        return
                    }
                }
            }
            // Record after a clean disconnect or separately confirmed recovery,
            // while holding the gate so polling cannot race the preparation.
            if recordIntent {
                setPresetKeptOffHandler?(preset, true)
            }
            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                message = "Stopping GlobalProtect and its services…"
            }

            let inventoryWasAvailable: Bool
            switch await currentSnapshot(for: preset) {
            case .success:
                inventoryWasAvailable = true
            case .failure:
                inventoryWasAvailable = false
            }
            let userDisable = await lifecycle.disableUserLaunchAgents(for: preset)
            let systemDisable = preset.hasCanonicalGlobalProtectIdentity
                ? await lifecycle.disableSystemLaunchDaemons(for: preset, allowAdministratorPrompt: recordIntent)
                : .notNeeded
            let disableResult = LifecycleBatchResult(jobs: userDisable.jobs + systemDisable.jobs)
            diagnosticJobs += disableResult.jobs
            // Background enforcement runs on every launch and poll tick; only a
            // failure is worth interrupting the user with a report sheet.
            if recordIntent || !disableResult.succeeded {
                lifecycleReport = disableResult.jobs.isEmpty
                    ? nil
                    : LifecycleReport(
                        title: "\(preset.displayName) Keep Off",
                        jobs: disableResult.jobs
                    )
            }

            guard inventoryWasAvailable else {
                message = disableResult.succeeded
                    ? "Keep Off disabled relaunch jobs, but the process list was unavailable; running processes were not signalled and enforcement will retry."
                    : "Keep Off remains enabled, but TaskScope could neither verify processes nor disable relaunch jobs."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let terminationOutcomes = await terminateProcesses(for: preset, scope: .all)
            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                message = "Verifying GlobalProtect is off…"
            }
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()
            let nowSnapshot = snapshot(for: preset)

            if !disableResult.succeeded {
                message = "Keep Off was requested, but stopping services failed: \(disableResult.failureSummary ?? "unknown failure")."
                diagnosticReason = systemDisable.succeeded ? .userLaunchAgentFailed : .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.inventoryUnavailable) {
                message = "Keep Off disabled relaunch jobs, but the process list became unavailable before app processes could be stopped."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.signalRejected) {
                message = "Keep Off disabled relaunch jobs, but a running process rejected the stop signal."
                diagnosticReason = .signalRejected
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if terminationOutcomes.contains(.escalationUnavailable) || !refreshed {
                message = "Keep Off is enabled, but TaskScope could not verify the final process state."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if preset.hasCanonicalGlobalProtectIdentity && !nowSnapshot.protectedRunning.isEmpty {
                message = "Keep Off was requested, but a privileged VPN service is still running. Choose Apply Keep Off to retry with administrator approval."
                diagnosticReason = .stillRunning
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if nowSnapshot.hasKeepOffTargets {
                message = "Keep Off is enabled, but user-facing GlobalProtect processes may still run."
                diagnosticReason = .stillRunning
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else {
                if preset.hasCanonicalGlobalProtectIdentity {
                    message = "GlobalProtect is off. Its user agents and system VPN service are disabled. Choose Open to restore them without reinstalling."
                } else if !nowSnapshot.protectedRunning.isEmpty {
                    message = "\(preset.displayName) app is kept off. Protected system service remains available."
                } else if !nowSnapshot.unprivilegedProtectedRunning.isEmpty {
                    let names = nowSnapshot.unprivilegedProtectedRunning.joined(separator: ", ")
                    message = "\(preset.displayName) is kept off. Its user launch agents are disabled; a per-user \(names) instance is still running and should exit as launchd finishes unloading it."
                } else {
                    message = "\(preset.displayName) is kept off. Its user launch agents are disabled."
                }
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            }
        }
        return commandResult
    }

    /// Clears suppression of the services required by this installation without
    /// launching the app. A separate system daemon stays disabled when the
    /// installed session agent supplies the VPN service. Only Open starts it.
    @discardableResult
    func allowToRun(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Could not allow \(preset.displayName) to run."
        )
        await runAction(kind: .mutation) {
            if preset.hasCanonicalGlobalProtectIdentity { globalProtectDisconnectFailureID = nil }
            var diagnosticReason: LifecycleDiagnosticFailure.Reason = .incomplete
            var diagnosticJobs: [LifecycleJobResult] = []
            defer {
                if commandResult.status == .failed {
                    lifecycleDiagnostics.record(
                        presetID: preset.id, action: .allowToRun,
                        backgroundEnforcement: false, reason: diagnosticReason,
                        jobs: diagnosticJobs, at: now()
                    )
                }
            }
            let systemEnable = preset.hasCanonicalGlobalProtectIdentity
                ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
            // Do not start restoring user jobs after a cancelled system request.
            let userEnable = systemEnable.succeeded
                ? await lifecycle.enableUserLaunchAgents(for: preset) : .notNeeded
            let enableResult = LifecycleBatchResult(jobs: systemEnable.jobs + userEnable.jobs)
            diagnosticJobs += enableResult.jobs
            lifecycleReport = enableResult.jobs.isEmpty
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Keep Off",
                    jobs: enableResult.jobs
                )
            guard enableResult.succeeded else {
                message = "Keep Off remains requested: \(enableResult.failureSummary ?? "service could not be enabled")."
                diagnosticReason = systemEnable.succeeded ? .userLaunchAgentFailed : .systemServiceFailed
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
    /// is restored externally. The system disable override persists in launchd;
    /// polling never requests authorization or repeatedly fights a restored system
    /// service. Its running state stays visible with an explicit retry action.
    ///
    /// Enforcement never queues behind a user-initiated mutation: while one runs
    /// the user is changing exactly the state enforcement would act on, and the
    /// gated re-check inside `keepOff` is the last line of defence for a tick
    /// that had already decided before the mutation started.
    func enforceKeptOffPresets(force: Bool = false) async {
        for preset in keptOffPresetsProvider?() ?? [] {
            guard operationGate.state != .runningMutation else { continue }
            if !force {
                guard case .success(let current) = await currentSnapshot(for: preset),
                      current.hasKeepOffTargets else {
                    continue
                }
            }
            _ = await keepOff(preset, recordIntent: false)
        }
    }

    @discardableResult
    func quitMainApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .app)
    }

    @discardableResult
    func quitHelpers(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .helpers)
    }

    @discardableResult
    func quitAll(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if preset.hasCanonicalGlobalProtectIdentity {
            return await keepOff(preset)
        }
        return await quitAllKillable(preset)
    }

    /// Existing URL and Shortcuts commands retain their user-process scope.
    /// The full VPN stop is requested by the explicitly confirmed in-app action.
    @discardableResult
    func quitAllKillable(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .all)
    }

    private func stop(_ preset: WatchedAppPreset, scope: PresetStopScope) async -> TaskScopeCommandResult {
        var result = PresetStopResult.failed(scope.incompleteMessage, reason: .incomplete)
        await runAction(kind: .mutation) {
            var diagnosticJobs: [LifecycleJobResult] = []
            defer {
                message = result.message
                if let reason = result.failureReason {
                    lifecycleDiagnostics.record(
                        presetID: preset.id, action: scope.diagnosticAction,
                        backgroundEnforcement: false, reason: reason,
                        jobs: diagnosticJobs, at: now()
                    )
                }
            }
            guard case .success(let before) = await currentSnapshot(for: preset) else {
                result = scope.inventoryFailure(for: preset)
                return
            }
            let agents: LifecycleBatchResult
            if scope == .helpers {
                // Unloading an agent running the main binary would also quit the app.
                agents = await lifecycle.unloadUserLaunchAgents(
                    for: preset, preservingPIDs: before.mainProcessPIDs
                )
            } else {
                agents = await lifecycle.unloadUserLaunchAgents(for: preset)
            }
            diagnosticJobs = agents.jobs
            lifecycleReport = agents.jobs.isEmpty
                ? nil
                : LifecycleReport(title: "\(preset.displayName) Relaunch Jobs", jobs: agents.jobs)
            let terminations = await terminateProcesses(for: preset, scope: scope)
            await lifecycle.settleAfterProcessChange()
            let refreshed = await refreshAfterMutation()
            result = scope.result(
                before: before, after: snapshot(for: preset),
                terminations: terminations, agents: agents, refreshed: refreshed
            )
        }
        return result.commandResult
    }

    private func terminateProcesses(
        for preset: WatchedAppPreset,
        scope: PresetStopScope
    ) async -> [ProcessTerminationOutcome] {
        var outcomes: [ProcessTerminationOutcome] = []
        if scope != .helpers {
            outcomes.append(await lifecycle.terminateMainProcess(for: preset))
        }
        if scope != .app {
            for name in preset.helperProcessNames {
                outcomes.append(await lifecycle.terminateHelperProcess(named: name, for: preset))
            }
        }
        return outcomes
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
        guard ProcessSignalGuard.isSignalablePID(process.pid) else {
            message = "PID \(process.pid) can never be signalled."
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
            let delivery = processSignaler.deliver(signal, to: process.pid)
            await settleAfterProcessChange()

            switch delivery {
            case .rejected:
                message = "Could not send \(forceKill ? "force stop" : "stop") to \(process.name)."
                result = .rejected
            case .noSuchProcess:
                // It exited between the identity check and the signal; the
                // requested outcome holds.
                message = "\(process.name) had already exited."
                result = .stopped
            case .delivered:
                if !processSignaler.isAlive(process.pid) {
                    message = forceKill ? "\(process.name) force stopped." : "\(process.name) stopped."
                    result = .stopped
                } else if forceKill {
                    message = "\(process.name) is still running after Force Stop."
                    result = .requestedStillRunning
                } else {
                    message = "Stop requested for \(process.name); it is still running."
                    result = .requestedStillRunning
                }
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
        listProjection.ppidMap
    }

    @discardableResult
    private func refreshAfterMutation() async -> Bool {
        await refreshInventoryAfterMutation() != nil
    }

    private func refreshInventoryAfterMutation() async -> [AppProcess]? {
        switch await verificationInventory.load(fetchExtendedStats: hasLoadedProcessList && fetchExtendedStats) {
        case .success(let inventory):
            recordInventorySuccess(clearsProcessLoadError: hasLoadedProcessList)
            apply(snapshots(from: inventory))
            if hasLoadedProcessList {
                fullProcessInventory = inventory
                publishDisplayProcesses()
            }
            return inventory
        case .failure(let error):
            recordInventoryFailure(error)
            return nil
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
        lastInventoryFailure = nil
        successfulInventoryReads &+= 1
    }

    /// A cancelled read (a poll restart, a torn-down view) says nothing about
    /// the inventory and never becomes the persistent "stale list" error.
    private func recordInventoryFailure(_ error: ProcessInventoryError) {
        let failure = Task.isCancelled ? ProcessInventoryError.cancelled : error
        lastInventoryFailure = failure.localizedDescription
        guard failure != .cancelled else { return }
        processLoadError = failure.localizedDescription
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

    /// The selection is reconciled against the *full* inventory, not the top-N
    /// display slice: a process selected through search can rank below the
    /// display limit and must survive a poll or a sort change. Exited or
    /// recycled PIDs are still pruned because their identity is gone.
    private func publishDisplayProcesses() {
        processes = displayProcesses()
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
