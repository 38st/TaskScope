import Darwin
import XCTest
@testable import TaskScope

@MainActor
final class ProcessManagerTests: XCTestCase {
    func testMemorySortSelectsFromFullInventoryBeforeApplyingLimit() async {
        let highCPU = process(pid: 1, cpu: 90, memory: 10, name: "HighCPU")
        let mediumCPU = process(pid: 2, cpu: 80, memory: 20, name: "MediumCPU")
        let highMemory = process(pid: 3, cpu: 0, memory: 2_000, name: "HighMemory")
        let inventory = FakeProcessInventory(results: [.success([highCPU, mediumCPU, highMemory])])
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 2 }
        manager.sortKey = .memory

        await manager.loadProcessList()

        XCTAssertEqual(manager.processes.map(\.pid), [3, 2])
        XCTAssertEqual(manager.message, "Loaded 2 of 3 processes.")
    }

    func testChangingSortRecomputesMembershipFromFullInventory() async {
        let highCPU = process(pid: 1, cpu: 90, memory: 10, name: "HighCPU")
        let mediumCPU = process(pid: 2, cpu: 80, memory: 20, name: "MediumCPU")
        let highMemory = process(pid: 3, cpu: 0, memory: 2_000, name: "HighMemory")
        let inventory = FakeProcessInventory(results: [.success([highCPU, mediumCPU, highMemory])])
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 2 }

        await manager.loadProcessList()
        XCTAssertEqual(manager.processes.map(\.pid), [1, 2])

        manager.sortKey = .memory

        XCTAssertEqual(manager.processes.map(\.pid), [3, 2])
    }

    func testFilteringOccursBeforeLimitSoOffscreenWatchedTargetIsDiscoverable() async {
        let highCPU = process(pid: 1, cpu: 90, name: "HighCPU")
        let watched = process(pid: 2, cpu: 0, name: "Watched")
        let inventory = FakeProcessInventory(results: [.success([highCPU, watched])])
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 1 }

        await manager.loadProcessList()

        XCTAssertEqual(manager.processes.map(\.pid), [highCPU.pid])
        XCTAssertEqual(
            manager.displayProcesses { $0.name == "Watched" }.map(\.pid),
            [watched.pid]
        )
    }

    func testFullInventoryRetainsAncestorOutsideDisplayLimitForTreeContext() async {
        let parent = AppProcess(
            pid: 10,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: "Parent",
            elapsedTime: "00:10",
            startTime: "parent-start",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
        let child = AppProcess(
            pid: 11,
            parentPID: parent.pid,
            cpu: 90,
            memoryMB: 0,
            command: "Child",
            elapsedTime: "00:10",
            startTime: "child-start",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
        let inventory = FakeProcessInventory(results: [.success([parent, child])])
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 1 }

        await manager.loadProcessList()
        let roots = ProcessTreeBuilder.build(
            from: manager.inventorySnapshot,
            ppidMap: manager.ppidMap,
            matchingPIDs: Set(manager.processes.map(\.pid))
        )

        XCTAssertEqual(manager.processes.map(\.pid), [child.pid])
        XCTAssertEqual(roots.map(\.process.pid), [parent.pid])
        XCTAssertEqual(roots.first?.children.map(\.process.pid), [child.pid])
    }

    func testWatchedNamesWithRegexCharactersMatchLiterally() async {
        var watched = process(pid: 42, name: "Codex (Renderer)")
        watched.command = "/Applications/Renderer.app/Contents/MacOS/Codex (Renderer)"
        watched.executablePath = watched.command
        let inventory = FakeProcessInventory(results: [.success([watched])])
        let manager = makeManager(inventory: inventory)
        let preset = WatchedAppPreset(
            displayName: "Renderer",
            mainProcessName: "Codex (Renderer)",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Renderer.app"
        )
        manager.watchedAppsProvider = { [preset] }

        await manager.refreshWatchedStatus()

        XCTAssertEqual(manager.snapshots.first?.runningNames, ["Codex (Renderer)"])
        XCTAssertEqual(manager.status, .watchedRunning)
    }

    func testWatchedStatusRequiresExecutablePathFromLivePSSchema() async {
        var basenameOnly = process(pid: 41, name: "Example")
        basenameOnly.command = "Example"
        basenameOnly.executablePath = nil
        var liveShaped = process(pid: 42, name: "Example")
        liveShaped.command = "/Applications/Example.app/Contents/MacOS/Example"
        let inventory = FakeProcessInventory(results: [
            .success([basenameOnly]),
            .success([liveShaped])
        ])
        let manager = makeManager(inventory: inventory)
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        manager.watchedAppsProvider = { [preset] }

        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertFalse(manager.snapshots[0].isMainRunning)

        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertTrue(manager.snapshots[0].isMainRunning)
    }

    func testLoadFailureRetainsLastGoodProcessList() async {
        let original = process(pid: 42, name: "Original")
        let inventory = FakeProcessInventory(
            results: [
                .success([original]),
                .failure(.commandFailed("temporary failure"))
            ]
        )
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        let lastSuccess = manager.lastSuccessfulInventoryAt
        await manager.loadProcessList()

        XCTAssertEqual(manager.processes, [original])
        XCTAssertNotNil(lastSuccess)
        XCTAssertEqual(manager.lastSuccessfulInventoryAt, lastSuccess)
        XCTAssertEqual(manager.processLoadError, "temporary failure")
        XCTAssertEqual(manager.message, "Could not load processes: temporary failure")
    }

    /// A poll restart or view teardown cancels the running read. That says
    /// nothing about the inventory and must not raise the stale-list banner.
    func testCancelledInventoryReadIsNotRecordedAsALoadError() async {
        let original = process(pid: 42, name: "Original")
        let inventory = CancellationAwareInventory(processes: [original])
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        XCTAssertNil(manager.processLoadError)

        let reload = Task { await manager.loadProcessList(showMessage: false) }
        await inventory.waitForBlockedCall()
        reload.cancel()
        await inventory.releaseBlockedCall()
        await reload.value

        XCTAssertNil(manager.processLoadError, "a cancelled read must not become a persistent load error")
        XCTAssertEqual(manager.processes, [original])
        XCTAssertEqual(manager.operationState, .idle)
    }

    func testDisplayListsAreMemoizedPerInventoryGeneration() async {
        let first = process(pid: 10, cpu: 90, name: "First")
        let second = process(pid: 20, cpu: 10, name: "Second")
        let inventory = FakeProcessInventory(results: [.success([first, second]), .success([second])])
        let manager = makeManager(inventory: inventory)
        let query = ProcessListQuery(
            searchText: "",
            filterMode: .all,
            watchedNames: [],
            cpuHighlightThreshold: 30,
            memoryHighlightThresholdMB: 1_024
        )

        await manager.loadProcessList()
        let generation = manager.inventoryGeneration
        XCTAssertEqual(manager.displayProcesses(for: query).map(\.pid), [10, 20])
        XCTAssertEqual(manager.treeRoots(for: query).map(\.id), [10, 20])
        XCTAssertEqual(manager.displayProcesses(for: query), manager.displayProcesses(matching: query.matches))

        manager.sortKey = .name
        XCTAssertEqual(manager.displayProcesses(for: query).map(\.pid), [10, 20])
        manager.sortKey = .pid

        await manager.loadProcessList()
        XCTAssertNotEqual(manager.inventoryGeneration, generation)
        XCTAssertEqual(manager.displayProcesses(for: query).map(\.pid), [20])
        XCTAssertEqual(manager.treeRoots(for: query).map(\.id), [20])
    }

    func testSelectionIsPrunedWhenPIDRepresentsNewProcessIdentity() async {
        let original = process(pid: 42, startTime: "start-a", name: "Original")
        let replacement = process(pid: 42, startTime: "start-b", name: "Replacement")
        let inventory = FakeProcessInventory(results: [.success([original]), .success([replacement])])
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        manager.toggleSelection(42)
        XCTAssertEqual(manager.selectedPids, [42])

        await manager.loadProcessList()

        XCTAssertTrue(manager.selectedPids.isEmpty)
        XCTAssertTrue(manager.selectionSnapshot().isEmpty)
    }

    /// The selection is reconciled against the full inventory, not the top-N
    /// display slice, so a process that drops below the display limit on the
    /// next poll stays selected. Only an exited or recycled identity is pruned.
    func testSelectionSurvivesWhenProcessFallsOutsideRefreshedDisplayLimit() async {
        let target = process(pid: 42, cpu: 90, name: "Target")
        let other = process(pid: 43, cpu: 10, name: "Other")
        let promoted = process(pid: 44, cpu: 100, name: "Promoted")
        let inventory = FakeProcessInventory(
            results: [
                .success([target, other]),
                .success([target, promoted])
            ]
        )
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 1 }

        await manager.loadProcessList()
        manager.toggleSelection(target.pid)
        XCTAssertEqual(manager.selectedPids, [target.pid])

        await manager.loadProcessList()

        XCTAssertEqual(manager.processes.map(\.pid), [promoted.pid])
        XCTAssertEqual(manager.selectedPids, [target.pid])
        XCTAssertEqual(manager.selectionSnapshot(), [target.identity])
    }

    /// A row surfaced by search can rank below the display limit. Selecting it
    /// and then polling, or changing the sort, must not deselect it.
    func testSearchedSelectionBelowTheDisplayLimitSurvivesRefreshAndSortChange() async {
        let hotA = process(pid: 91, cpu: 90, memory: 10, name: "HotA")
        let hotB = process(pid: 92, cpu: 80, memory: 20, name: "HotB")
        let needle = process(pid: 93, cpu: 1, memory: 5, name: "Needle")
        let inventory = FakeProcessInventory(results: [.success([hotA, hotB, needle])])
        let manager = makeManager(inventory: inventory)
        manager.processListLimitProvider = { 2 }

        await manager.loadProcessList()
        XCTAssertEqual(manager.processes.map(\.pid), [91, 92])
        XCTAssertEqual(manager.displayProcesses { $0.name == "Needle" }.map(\.pid), [93])
        manager.toggleSelection(needle.pid)
        XCTAssertEqual(manager.selectedPids, [93])

        await manager.loadProcessList()
        XCTAssertEqual(manager.selectedPids, [93], "a poll must not deselect a row outside the display slice")

        manager.sortKey = .memory
        XCTAssertEqual(manager.selectedPids, [93], "a sort change must not deselect a row outside the display slice")
        manager.sortKey = .name
        XCTAssertEqual(manager.selectedProcessesSnapshot().map(\.pid), [93])
    }

    func testSelectUsesOnlyProvidedVisibleProcesses() async {
        let first = process(pid: 1, name: "First")
        let second = process(pid: 2, name: "Second")
        let inventory = FakeProcessInventory(results: [.success([first, second])])
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        manager.select([second])

        XCTAssertEqual(manager.selectedPids, [2])
        XCTAssertEqual(manager.selectionSnapshot(), [second.identity])
    }

    func testNormalStopNeverEscalatesToSIGKILL() async {
        let target = process(pid: 42, name: "SlowExit")
        let inventory = FakeProcessInventory(results: [.success([target]), .success([target])])
        let signaler = FakeProcessSignaler(alivePids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.terminate(target)

        XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM])
        XCTAssertEqual(manager.message, "Stop requested for SlowExit; it is still running.")
    }

    func testForceStopUsesSIGKILL() async {
        let target = process(pid: 42, name: "Frozen")
        let inventory = FakeProcessInventory(results: [.success([target]), .success([])])
        let signaler = FakeProcessSignaler(alivePids: [42], exitsOnKill: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.terminate(target, forceKill: true)

        XCTAssertEqual(signaler.sent.map(\.signal), [SIGKILL])
        XCTAssertEqual(manager.message, "Frozen force stopped.")
    }

    /// PID 1 is launchd and 0 or a negative value would signal a whole process
    /// group. None of them may ever reach `kill(2)`, even when an inventory row
    /// claims one as a target.
    func testTerminateRefusesPIDsThatMustNeverBeSignalled() async {
        let launchd = process(pid: 1, name: "launchd")
        let inventory = FakeProcessInventory(results: [.success([launchd])])
        let signaler = FakeProcessSignaler(alivePids: [1])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        let result = await manager.terminate(launchd)

        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.message, "PID 1 can never be signalled.")
    }

    /// `ESRCH` after the identity check means the target exited in the gap;
    /// the requested outcome holds and must not be reported as a rejected signal.
    func testSignalToAProcessThatAlreadyExitedCountsAsStopped() async {
        let target = process(pid: 42, name: "Gone")
        let inventory = FakeProcessInventory(results: [.success([target]), .success([])])
        let signaler = FakeProcessSignaler(missingPids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        let result = await manager.terminate(target)

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(manager.message, "Gone had already exited.")
    }

    func testBatchStopReportsAnAlreadyExitedTargetAsStoppedNotRejected() async {
        let gone = process(pid: 42, name: "Gone")
        let inventory = FakeProcessInventory(results: [.success([gone]), .success([])])
        let signaler = FakeProcessSignaler(missingPids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.batchTerminate([gone.identity])

        XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.stopped])
        XCTAssertEqual(manager.message, "Stopped 1 of 1 selected.")
    }

    func testTerminateRejectsReusedPIDBeforeSignaling() async {
        let original = process(pid: 42, startTime: "start-a", name: "Original")
        let replacement = process(pid: 42, startTime: "start-b", name: "Replacement")
        let inventory = FakeProcessInventory(results: [.success([replacement])])
        let signaler = FakeProcessSignaler(alivePids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.terminate(original)

        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.message, "Original is no longer the same running process.")
    }

    func testTerminateRejectsExecutableChangeBeforeSignaling() async {
        let original = process(pid: 42, startTime: "start-a", name: "Original")
        var replacement = original
        replacement.executablePath = "/tmp/Original"
        let inventory = FakeProcessInventory(results: [.success([replacement])])
        let signaler = FakeProcessSignaler(alivePids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.terminate(original)

        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.message, "Original is no longer the same running process.")
    }

    func testBatchStopSignalsTheConfirmedIdentitySnapshotOnly() async {
        let confirmed = process(pid: 42, startTime: "start-a", name: "Confirmed")
        let replacement = process(pid: 42, startTime: "start-b", name: "Replacement")
        let inventory = FakeProcessInventory(results: [.success([replacement]), .success([replacement])])
        let signaler = FakeProcessSignaler(alivePids: [42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.batchTerminate([confirmed.identity])

        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.message, "Selection changed; 1 no longer matched. Nothing was stopped.")
    }

    func testBatchStopReportsStoppedRejectedAndStaleTargetsIndividually() async {
        let stopped = process(pid: 40, name: "Stopped")
        let rejected = process(pid: 41, name: "Rejected")
        let stale = process(pid: 42, name: "Stale")
        let inventory = FakeProcessInventory(
            results: [
                .success([stopped, rejected]),
                .success([rejected])
            ]
        )
        let signaler = FakeProcessSignaler(
            alivePids: [40, 41],
            exitsOnTerminate: true,
            rejectedPids: [41]
        )
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.batchTerminate([stopped.identity, rejected.identity, stale.identity])

        XCTAssertEqual(
            manager.batchActionReport?.targets.map(\.state),
            [.stopped, .signalRejected, .stale]
        )
        XCTAssertEqual(
            manager.batchActionReport?.targets.map(\.name),
            ["Stopped", "Rejected", "Stale"]
        )
        XCTAssertEqual(manager.message, "Stop requested; 1 still running, 1 no longer matched.")
    }

    func testBatchStopReportsTaskScopeSelfTargetInsteadOfOmittingIt() async {
        let taskScope = process(
            pid: ProcessInfo.processInfo.processIdentifier,
            name: "TaskScope"
        )
        let inventory = FakeProcessInventory(results: [.success([taskScope])])
        let signaler = FakeProcessSignaler(alivePids: [taskScope.pid])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.batchTerminate([taskScope.identity])

        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.selfProcess])
        XCTAssertEqual(manager.batchActionReport?.targets.map(\.identity), [taskScope.identity])
        XCTAssertEqual(manager.message, "TaskScope cannot stop itself; use Quit.")
    }

    func testEquivalentOverlappingRefreshesAreCoalesced() async {
        let inventory = BlockingProcessInventory()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: FakeProcessSignaler(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false

        let first = Task { await manager.refreshWatchedStatus(showMessage: false) }
        await inventory.waitForFirstCall()
        let second = Task { await manager.refreshWatchedStatus(showMessage: false) }
        await Task.yield()

        let countWhileBlocked = await inventory.currentLoadCount()
        XCTAssertEqual(countWhileBlocked, 1)

        await inventory.finishFirstCall()
        _ = await first.value
        _ = await second.value

        let finalCount = await inventory.currentLoadCount()
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(manager.operationState, .idle)
    }

    func testQueuedTerminationRechecksAuthorityImmediatelyBeforeSignal() async {
        let target = process(pid: 88, name: "Revoked")
        let inventory = OrderedBlockingProcessInventory(results: [.success([target])])
        let signaler = FakeProcessSignaler(alivePids: [target.pid])
        let manager = makeManager(inventory: inventory, signaler: signaler)
        var isAuthorized = true

        let termination = Task {
            await manager.terminate(target, isAuthorized: { isAuthorized })
        }
        await inventory.waitForFirstCall()
        isAuthorized = false
        await inventory.finishFirstCall()

        let result = await termination.value
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(manager.message, "Stop for Revoked was cancelled.")
    }

    func testCancellingQueuedRefreshRemovesItWithoutPublishingObsoleteWork() async {
        let inventory = BlockingProcessInventory()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: FakeProcessSignaler(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false

        let activeRefresh = Task {
            await manager.refreshWatchedStatus(showMessage: false)
        }
        await inventory.waitForFirstCall()
        let queuedRefresh = Task {
            await manager.loadProcessList(showMessage: false)
        }
        await Task.yield()

        queuedRefresh.cancel()
        await inventory.finishFirstCall()
        _ = await activeRefresh.value
        await queuedRefresh.value

        let finalLoadCount = await inventory.currentLoadCount()
        XCTAssertEqual(finalLoadCount, 1)
        XCTAssertFalse(manager.hasLoadedProcessList)
        XCTAssertEqual(manager.operationState, .idle)
    }

    func testQueuedMutationRunsBeforeDifferentQueuedRefresh() async {
        let initial = process(pid: 42, name: "Target")
        let inventory = OrderedBlockingProcessInventory(
            results: [
                .success([]),
                .success([initial]),
                .success([]),
                .success([])
            ]
        )
        let signaler = FakeProcessSignaler(alivePids: [42], exitsOnTerminate: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)

        let activeRefresh = Task { await manager.refreshWatchedStatus(showMessage: false) }
        await inventory.waitForFirstCall()
        let queuedListRefresh = Task { await manager.loadProcessList(showMessage: false) }
        let queuedMutation = Task { await manager.terminate(initial) }
        await Task.yield()

        await inventory.finishFirstCall()
        _ = await activeRefresh.value
        _ = await queuedMutation.value
        await queuedListRefresh.value

        XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM])
        let fetchOrder = await inventory.fetchOrder()
        XCTAssertEqual(fetchOrder, [false, false, false, false])
        XCTAssertEqual(manager.operationState, .idle)
    }

    func testOpenLifecycleOrdersDependenciesBeforeAppAndVerification() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([]), .success([]), .success([process(pid: 42, name: "Example")])]),
            lifecycle: lifecycle
        )
        let preset = lifecyclePreset()

        await manager.openApp(preset)

        XCTAssertEqual(lifecycle.calls, [
            "exists",
            "daemon",
            "agents.load",
            "open",
            "wait"
        ])
        XCTAssertEqual(manager.message, "Opened Example.")
    }

    func testOpenRelaunchesWhenExistingAppExitsDuringServiceWork() async {
        let lifecycle = FakeLifecycleService()
        let running = process(pid: 42, name: "Example")
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([running]), .success([]), .success([running])]),
            lifecycle: lifecycle
        )
        let result = await manager.openApp(lifecyclePreset())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load", "open", "wait"])
    }

    func testOpenDoesNotAcceptAnEarlierRunningObservationAfterAppExits() async {
        for initiallyRunning in [false, true] {
            let lifecycle = FakeLifecycleService()
            let running = process(pid: 42, name: "Example")
            let manager = makeManager(
                inventory: FakeProcessInventory(results: [
                    .success(initiallyRunning ? [running] : []),
                    .success(initiallyRunning ? [running] : []),
                    .success([])
                ]),
                lifecycle: lifecycle
            )
            let result = await manager.openApp(lifecyclePreset())
            XCTAssertFalse(result.succeeded, "Neither an old snapshot nor a successful wait can override final absence")
            XCTAssertTrue(result.message.contains("could not be verified"))
        }
    }

    func testOpenRechecksInitiallyRunningAppWhenPostServiceInventoryFails() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([process(pid: 42, name: "Example")]),
                .failure(.commandFailed("unavailable"))
            ]),
            lifecycle: lifecycle
        )
        let result = await manager.openApp(lifecyclePreset())
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load"])
    }

    func testOpenFailsClosedWhenFreshInventoryIsUnavailable() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let running = process(pid: 42, name: "Example")
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([running]),
                .failure(.commandFailed("inventory unavailable"))
            ]),
            lifecycle: lifecycle
        )
        manager.watchedAppsProvider = { [preset] }

        await manager.refreshWatchedStatus(showMessage: false)
        let result = await manager.openApp(preset)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("nothing was opened"))
        XCTAssertEqual(lifecycle.calls, ["exists"])
        XCTAssertEqual(manager.processLoadError, "inventory unavailable")
    }

    func testOpenReportsFailureWhenFinalInventoryCannotBeVerified() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([]),
                .success([]),
                .failure(.commandFailed("final inventory unavailable"))
            ]),
            lifecycle: lifecycle
        )

        let result = await manager.openApp(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("could not verify its final state"))
        XCTAssertEqual(lifecycle.calls, [
            "exists",
            "daemon",
            "agents.load",
            "open",
            "wait"
        ])
        XCTAssertEqual(manager.processLoadError, "final inventory unavailable")
    }

    /// GlobalProtect's `pangpa` launch agent runs the main binary, so restoring
    /// the agents can start the app by itself. Open must re-check before it
    /// launches, otherwise `open` produced a second instance.
    func testOpenSkipsLaunchWhenRestoredServicesAlreadyStartedTheMainProcess() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let running = process(pid: 42, name: "Example")
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([]),
                .success([running])
            ]),
            lifecycle: lifecycle
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.openApp(preset)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load"])
        XCTAssertFalse(lifecycle.calls.contains("open"))
        XCTAssertEqual(manager.message, "Opened Example.")
    }

    func testOpenFailsClosedWhenPostServiceInventoryIsUnavailable() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([]),
                .failure(.commandFailed("inventory unavailable"))
            ]),
            lifecycle: lifecycle
        )

        let result = await manager.openApp(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("nothing was opened"), result.message)
        XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load"])
    }

    func testMissingAppBundleCausesNoLifecycleMutation() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.appExists = false
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        await manager.openApp(lifecyclePreset())

        XCTAssertEqual(lifecycle.calls, ["exists"])
        XCTAssertTrue(manager.message.contains("app bundle is missing"))
    }

    func testDaemonFailurePreventsAgentAndAppLaunch() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.daemonResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "daemon", state: .failed, detail: "approval cancelled")
        ])
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        await manager.openApp(lifecyclePreset())

        XCTAssertEqual(lifecycle.calls, ["exists", "daemon"])
        XCTAssertTrue(manager.message.contains("approval cancelled"))
    }

    func testManagedQuitUnloadsConfiguredAgentsEvenWhenHelpersAreAbsent() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        await manager.quitHelpers(lifecyclePreset())

        XCTAssertEqual(lifecycle.calls.first, "agents.unload")
        XCTAssertTrue(lifecycle.calls.contains("terminate.helper:ExampleHelper"))
    }

    /// Quit Helpers must leave a launch agent loaded when it is the one running
    /// the main process, otherwise booting it out quits the app.
    func testQuitHelpersPreservesLaunchAgentsRunningTheMainProcess() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let main = process(pid: 42, name: "Example")
        let helper = process(pid: 43, name: "ExampleHelper")
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([main, helper]),
                .success([main])
            ]),
            lifecycle: lifecycle
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.quitHelpers(preset)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(lifecycle.preservedPIDs, [[42]])
        XCTAssertEqual(lifecycle.calls.first, "agents.unload")
    }

    func testManagedStopReturnsTypedFailureWhenTargetStillRuns() async {
        let running = process(pid: 42, name: "Example")
        let preset = lifecyclePreset()
        let manager = makeManager(
            inventory: FakeProcessInventory(
                results: [.success([running]), .success([running])]
            ),
            lifecycle: FakeLifecycleService()
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.quitAllKillable(preset)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Example may still run.")
    }

    func testManagedQuitFailsWhenLifecycleSignalIsRejected() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.terminationOutcome = .signalRejected
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        let result = await manager.quitMainApp(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("signal was rejected"))
    }

    func testManagedHelperQuitFailsWhenEscalationCannotBeVerified() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.terminationOutcome = .escalationUnavailable
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        let result = await manager.quitHelpers(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("before Force Stop"))
    }

    func testManagedCloseFailsWhenAnyLifecycleSignalIsRejected() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.terminationOutcome = .signalRejected
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        let result = await manager.quitAllKillable(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("signal was rejected"))
    }

    func testKeepOffPersistsIntentDisablesAgentsAndLeavesProtectedServiceAlone() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let preset = lifecyclePreset()
        let protected = process(pid: 44, uid: 0, name: "ExampleDaemon")
        let inventory = FakeProcessInventory(results: [
            .success([
                process(pid: 42, name: "Example"),
                process(pid: 43, name: "ExampleHelper"),
                protected
            ]),
            .success([protected])
        ])
        let manager = makeManager(inventory: inventory, lifecycle: lifecycle)
        manager.watchedAppsProvider = { [preset] }
        var keptOff = false
        manager.setPresetKeptOffHandler = { _, value in keptOff = value }

        let result = await manager.keepOff(preset)

        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(keptOff)
        XCTAssertEqual(lifecycle.calls, [
            "agents.disable",
            "terminate:Example",
            "terminate.helper:ExampleHelper",
            "settle"
        ])
        XCTAssertFalse(lifecycle.calls.contains("terminate:ExampleDaemon"))
        XCTAssertTrue(result.message.contains("Protected system service remains available"))
    }

    func testKeepOffStillDisablesRelaunchJobsWhenInventoryIsUnavailable() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .failure(.commandFailed("ps unavailable"))
            ]),
            lifecycle: lifecycle
        )
        var keptOff = false
        manager.setPresetKeptOffHandler = { _, value in keptOff = value }

        let result = await manager.keepOff(lifecyclePreset())

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(keptOff)
        XCTAssertEqual(lifecycle.calls, ["agents.disable"])
        XCTAssertTrue(result.message.contains("running processes were not signalled"))
    }

    func testOpeningKeptOffPresetReEnablesAgentsAndClearsIntent() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentEnableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "enabled")
        ])
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([]), .success([]), .success([process(pid: 42, name: "Example")])]),
            lifecycle: lifecycle
        )
        var keptOff = true
        manager.isPresetKeptOffProvider = { _ in keptOff }
        manager.setPresetKeptOffHandler = { _, value in keptOff = value }

        let result = await manager.openApp(lifecyclePreset())

        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(keptOff)
        XCTAssertEqual(lifecycle.calls, [
            "exists",
            "daemon",
            "agents.enable",
            "agents.load",
            "open",
            "wait"
        ])
    }

    func testStartupEnforcementDisablesAgentsEvenWhenNoRunningStateIsKnown() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let preset = lifecyclePreset()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .failure(.commandFailed("ps unavailable"))
            ]),
            lifecycle: lifecycle
        )
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in true }

        await manager.enforceKeptOffPresets(force: true)

        XCTAssertEqual(lifecycle.calls, ["agents.disable"])
    }

    /// Enforcement runs on every launch and poll tick; a successful run must not
    /// raise the Keep Off report sheet.
    func testEnforcementPublishesNoReportWhenEveryJobSucceeds() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let preset = lifecyclePreset()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in true }

        await manager.enforceKeptOffPresets(force: true)

        XCTAssertEqual(lifecycle.calls.first, "agents.disable")
        XCTAssertNil(manager.lifecycleReport)
    }

    func testEnforcementPublishesAReportWhenAJobFails() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .failed, detail: "Operation not permitted")
        ])
        let preset = lifecyclePreset()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in true }

        await manager.enforceKeptOffPresets(force: true)

        XCTAssertEqual(manager.lifecycleReport?.jobs.map(\.state), [.failed])
    }

    func testUserKeepOffStillPublishesItsReport() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
            lifecycle: lifecycle
        )

        _ = await manager.keepOff(lifecyclePreset())

        XCTAssertEqual(manager.lifecycleReport?.jobs.map(\.state), [.changed])
    }

    func testEnforcementIsSkippedOnceIntentHasBeenCleared() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([process(pid: 42, name: "Example")])]),
            lifecycle: lifecycle
        )
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in false }

        let result = await manager.keepOff(preset, recordIntent: false)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(lifecycle.calls.isEmpty)
    }

    /// The poll tick decides to enforce, a user's Open then takes the gate and
    /// clears the Keep Off intent, and the queued enforcement runs afterwards. It
    /// must abort inside the gate instead of re-disabling the agents the user
    /// just restored and quitting the app they just opened.
    func testEnforcementQueuedBehindOpenDoesNotReDisableAgentsAfterOpenClearsIntent() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let running = process(pid: 42, name: "Example")
        let inventory = SequencedBlockingProcessInventory(
            results: [
                .success([running]),   // enforcement's ungated snapshot: app running
                .success([]),          // Open's fresh snapshot: not running yet
                .success([running]),   // Open's post-service re-check
                .success([running])    // Open's final refresh and anything later
            ],
            blockingFirstCalls: 2
        )
        let manager = makeManager(inventory: inventory, lifecycle: lifecycle)
        var keptOff = true
        manager.watchedAppsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in keptOff }
        manager.setPresetKeptOffHandler = { _, value in keptOff = value }
        manager.keptOffPresetsProvider = { keptOff ? [preset] : [] }

        let enforcement = Task { await manager.enforceKeptOffPresets() }
        await inventory.waitForCall(1)
        let open = Task { await manager.openApp(preset) }
        await inventory.waitForCall(2)

        await inventory.release(1)
        for _ in 0..<50 { await Task.yield() }
        await inventory.release(2)

        let openResult = await open.value
        await enforcement.value

        XCTAssertEqual(openResult.status, .completed, openResult.message)
        XCTAssertFalse(keptOff)
        XCTAssertFalse(
            lifecycle.calls.contains("agents.disable"),
            "enforcement re-disabled the agents after Open: \(lifecycle.calls)"
        )
        XCTAssertFalse(lifecycle.calls.contains("terminate:Example"))
        XCTAssertEqual(manager.operationState, .idle)
    }

    func testEnforcementSkipsWhileAMutationIsRunning() async {
        let lifecycle = FakeLifecycleService()
        let preset = lifecyclePreset()
        let inventory = SequencedBlockingProcessInventory(
            results: [.success([process(pid: 42, name: "Example")])],
            blockingFirstCalls: 1
        )
        let manager = makeManager(inventory: inventory, lifecycle: lifecycle)
        manager.watchedAppsProvider = { [preset] }
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in true }

        let quit = Task { await manager.quitMainApp(preset) }
        await inventory.waitForCall(1)
        XCTAssertEqual(manager.operationState, .runningMutation)

        await manager.enforceKeptOffPresets(force: true)

        XCTAssertFalse(lifecycle.calls.contains("agents.disable"))
        await inventory.release(1)
        _ = await quit.value
    }

    func testRoutineKeepOffEnforcementChecksFreshProcessState() async {
        let lifecycle = FakeLifecycleService()
        lifecycle.agentDisableResult = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "example.agent", state: .changed, detail: "disabled")
        ])
        let preset = lifecyclePreset()
        let running = process(pid: 42, name: "Example")
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [
                .success([running]),
                .success([running]),
                .success([])
            ]),
            lifecycle: lifecycle
        )
        manager.keptOffPresetsProvider = { [preset] }
        manager.isPresetKeptOffProvider = { _ in true }
        manager.watchedAppsProvider = { [preset] }

        await manager.enforceKeptOffPresets()

        XCTAssertEqual(lifecycle.calls, [
            "agents.disable",
            "terminate:Example",
            "terminate.helper:ExampleHelper",
            "settle"
        ])
    }

    func testKeepOffEnforcesCurrentUserPanGPSOnlyAndStopsRepeatingOnceGone() async {
        var agent = process(pid: 42, uid: getuid(), name: "PanGPS")
        agent.executablePath = "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([agent]), .success([agent]), .success([])]),
            lifecycle: lifecycle
        )
        manager.watchedAppsProvider = { [.globalProtect] }
        manager.keptOffPresetsProvider = { [.globalProtect] }
        manager.isPresetKeptOffProvider = { _ in true }
        await manager.enforceKeptOffPresets()
        await manager.enforceKeptOffPresets()

        XCTAssertEqual(lifecycle.calls.filter { $0 == "agents.disable" }.count, 1)
        XCTAssertFalse(lifecycle.calls.contains("terminate:PanGPS"))
        XCTAssertFalse(lifecycle.calls.contains("terminate.helper:PanGPS"))
        XCTAssertNil(manager.lifecycleReport)
    }

    func testKeepOffDoesNotClaimSuccessWhileCurrentUserAgentRemains() async {
        var agent = process(pid: 42, uid: getuid(), name: "PanGPS")
        agent.executablePath = "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([agent])]),
            lifecycle: lifecycle
        )
        manager.watchedAppsProvider = { [.globalProtect] }
        let result = await manager.keepOff(.globalProtect)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(manager.snapshots[0].hasKeepOffTargets)
        XCTAssertFalse(lifecycle.calls.contains("terminate:PanGPS"))
    }

    func testKeepOffSkipsRootOtherUsersAndUnrelatedPanGPSProcesses() async {
        for (uid, path) in [
            (uid_t(0), "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"),
            (getuid() + 1, "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"),
            (getuid(), "/tmp/PanGPS")
        ] {
            var agent = process(pid: 42, uid: uid, name: "PanGPS")
            agent.executablePath = path
            let lifecycle = FakeLifecycleService()
            let manager = makeManager(inventory: FakeProcessInventory(results: [.success([agent])]), lifecycle: lifecycle)
            manager.keptOffPresetsProvider = { [.globalProtect] }
            manager.isPresetKeptOffProvider = { _ in true }
            await manager.enforceKeptOffPresets()
            XCTAssertTrue(lifecycle.calls.isEmpty)
        }
    }

    func testExpandedMetricConsumersEnableCollectionAndRefreshLoadedList() async {
        let target = process(pid: 42, name: "Example")
        let inventory = FakeProcessInventory(results: [.success([target])])
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        await manager.beginExtendedMetrics()
        await manager.beginExtendedMetrics()

        XCTAssertEqual(inventory.fetchExtendedRequests, [false, true])
        XCTAssertTrue(manager.fetchExtendedStats)

        manager.endExtendedMetrics()
        XCTAssertTrue(manager.fetchExtendedStats)
        manager.endExtendedMetrics()
        XCTAssertFalse(manager.fetchExtendedStats)
    }

    /// `beginExtendedMetrics` is async, so a consumer's release can be delivered
    /// before its own acquire. That must not latch collection on permanently — the
    /// old `max(0, …)` clamp swallowed the early release, letting the late acquire
    /// enable collection with no consumer left able to disable it.
    func testReleaseDeliveredBeforeItsAcquireDoesNotLatchCollectionOn() async {
        let target = process(pid: 42, name: "Example")
        let inventory = FakeProcessInventory(results: [.success([target])])
        let manager = makeManager(inventory: inventory)

        await manager.loadProcessList()
        XCTAssertFalse(manager.fetchExtendedStats)

        manager.endExtendedMetrics()
        await manager.beginExtendedMetrics()

        XCTAssertFalse(
            manager.fetchExtendedStats,
            "a single consumer that came and went must leave collection disabled"
        )

        // A later, correctly ordered session must still work in both directions.
        await manager.beginExtendedMetrics()
        XCTAssertTrue(manager.fetchExtendedStats)
        manager.endExtendedMetrics()
        XCTAssertFalse(manager.fetchExtendedStats)
    }

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        signaler: FakeProcessSignaler = FakeProcessSignaler(),
        lifecycle: any ProcessLifecycleServicing = FakeLifecycleService()
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        return manager
    }

    private func lifecyclePreset() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: ["ExampleDaemon"],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(label: "example.agent", plistPath: "/Library/LaunchAgents/example.plist")
            ],
            systemLaunchDaemonJobs: [
                SystemLaunchDaemonJob(
                    label: "example.daemon",
                    plistPath: "/Library/LaunchDaemons/example.plist",
                    processName: "ExampleDaemon",
                    servicePort: 1234
                )
            ]
        )
    }

    private func process(
        pid: Int32,
        startTime: String = "Sat Jul 26 11:20:17 2026",
        uid: uid_t? = nil,
        cpu: Double = 0,
        memory: Double = 0,
        name: String
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: uid,
            cpu: cpu,
            memoryMB: memory,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "00:10",
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
    }
}

private final class FakeLifecycleService: ProcessLifecycleServicing, @unchecked Sendable {
    var appExists = true
    var daemonResult = LifecycleBatchResult.notNeeded
    var agentLoadResult = LifecycleBatchResult.notNeeded
    var agentUnloadResult = LifecycleBatchResult.notNeeded
    var agentDisableResult = LifecycleBatchResult.notNeeded
    var agentEnableResult = LifecycleBatchResult.notNeeded
    var openResult = true
    var waitResult = true
    var terminationOutcome = ProcessTerminationOutcome.signalled
    private(set) var calls: [String] = []
    private(set) var preservedPIDs: [Set<Int32>] = []

    func appBundleExists(at path: String) -> Bool {
        calls.append("exists")
        return appExists
    }

    func settleAfterProcessChange() async {
        calls.append("settle")
    }

    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        calls.append("terminate:\(preset.mainProcessName)")
        return terminationOutcome
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        calls.append("terminate.helper:\(name)")
        return terminationOutcome
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        calls.append("running:\(name)")
        return false
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.unload")
        return agentUnloadResult
    }

    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        preservedPIDs.append(preservingPIDs)
        calls.append("agents.unload")
        return agentUnloadResult
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.load")
        return agentLoadResult
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.disable")
        return agentDisableResult
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.enable")
        return agentEnableResult
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("daemon")
        return daemonResult
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        calls.append("wait")
        return waitResult
    }

    func openAppBundle(at path: String) async -> Bool {
        calls.append("open")
        return openResult
    }
}

private actor BlockingProcessInventory: ProcessInventoryProviding {
    private var firstCallContinuation: CheckedContinuation<Result<[AppProcess], ProcessInventoryError>, Never>?
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadCount = 0

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        loadCount += 1
        if loadCount == 1 {
            firstCallWaiters.forEach { $0.resume() }
            firstCallWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        return .success([])
    }

    func waitForFirstCall() async {
        guard loadCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    func finishFirstCall() {
        firstCallContinuation?.resume(returning: .success([]))
        firstCallContinuation = nil
    }

    func currentLoadCount() -> Int {
        loadCount
    }
}

/// Blocks the first `blockingFirstCalls` reads until the test releases each one
/// by number, so a test can interleave an ungated read, a gated mutation, and a
/// queued mutation deterministically.
private actor SequencedBlockingProcessInventory: ProcessInventoryProviding {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private let blockingFirstCalls: Int
    private var callCount = 0
    private var blocked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        results: [Result<[AppProcess], ProcessInventoryError>],
        blockingFirstCalls: Int
    ) {
        self.results = results
        self.blockingFirstCalls = blockingFirstCalls
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        callCount += 1
        let index = callCount
        let ready = callWaiters.filter { callCount >= $0.count }
        callWaiters.removeAll { callCount >= $0.count }
        ready.forEach { $0.continuation.resume() }

        if index <= blockingFirstCalls, !released.contains(index) {
            await withCheckedContinuation { blocked[index] = $0 }
        }
        guard !results.isEmpty else {
            return .failure(.commandFailed("No fake result configured."))
        }
        return results.count == 1 ? results[0] : results.removeFirst()
    }

    func waitForCall(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func release(_ index: Int) {
        released.insert(index)
        blocked[index]?.resume()
        blocked[index] = nil
    }
}

/// The second read blocks until released and honours cancellation of the task
/// that awaits it, mirroring how the real command runner reports `.cancelled`.
private actor CancellationAwareInventory: ProcessInventoryProviding {
    private let processes: [AppProcess]
    private var callCount = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        callCount += 1
        if callCount == 2 {
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            await withCheckedContinuation { blockedContinuation = $0 }
            if Task.isCancelled {
                return .failure(.cancelled)
            }
        }
        return .success(processes)
    }

    func waitForBlockedCall() async {
        guard callCount < 2 else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor OrderedBlockingProcessInventory: ProcessInventoryProviding {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [Bool] = []

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        requests.append(fetchExtendedStats)
        if requests.count == 1 {
            firstCallWaiters.forEach { $0.resume() }
            firstCallWaiters.removeAll()
            await withCheckedContinuation { continuation in
                firstCallContinuation = continuation
            }
        }
        guard !results.isEmpty else {
            return .failure(.commandFailed("No fake result configured."))
        }
        return results.removeFirst()
    }

    func waitForFirstCall() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    func finishFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func fetchOrder() -> [Bool] {
        requests
    }
}

private final class FakeProcessInventory: ProcessInventoryProviding, @unchecked Sendable {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private(set) var fetchExtendedRequests: [Bool] = []

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        fetchExtendedRequests.append(fetchExtendedStats)
        guard !results.isEmpty else {
            return .failure(.commandFailed("No fake result configured."))
        }
        if results.count == 1 {
            return results[0]
        }
        return results.removeFirst()
    }
}

private final class FakeProcessSignaler: ProcessSignaling {
    struct SentSignal: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private var alivePids: Set<Int32>
    private let exitsOnKill: Bool
    private let exitsOnTerminate: Bool
    private let rejectedPids: Set<Int32>
    private let missingPids: Set<Int32>
    private(set) var sent: [SentSignal] = []

    init(
        alivePids: Set<Int32> = [],
        exitsOnKill: Bool = false,
        exitsOnTerminate: Bool = false,
        rejectedPids: Set<Int32> = [],
        missingPids: Set<Int32> = []
    ) {
        self.alivePids = alivePids
        self.exitsOnKill = exitsOnKill
        self.exitsOnTerminate = exitsOnTerminate
        self.rejectedPids = rejectedPids
        self.missingPids = missingPids
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        if missingPids.contains(pid) {
            sent.append(SentSignal(signal: signal, pid: pid))
            return .noSuchProcess
        }
        return send(signal, to: pid) ? .delivered : .rejected(errno: EPERM)
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(SentSignal(signal: signal, pid: pid))
        if rejectedPids.contains(pid) {
            return false
        }
        if signal == SIGKILL, exitsOnKill {
            alivePids.remove(pid)
        }
        if signal == SIGTERM, exitsOnTerminate {
            alivePids.remove(pid)
        }
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        alivePids.contains(pid)
    }
}
