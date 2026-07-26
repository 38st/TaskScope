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

    func testWatchedNamesWithRegexCharactersMatchLiterally() async {
        let watched = process(pid: 42, name: "Codex (Renderer)")
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
        await manager.loadProcessList()

        XCTAssertEqual(manager.processes, [original])
        XCTAssertEqual(manager.processLoadError, "temporary failure")
        XCTAssertEqual(manager.message, "Could not load processes: temporary failure")
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

    func testOverlappingOperationsAreSerializedInsteadOfDropped() async {
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
        await first.value
        await second.value

        let finalCount = await inventory.currentLoadCount()
        XCTAssertEqual(finalCount, 2)
    }

    func testOpenLifecycleOrdersDependenciesBeforeAppAndVerification() async {
        let lifecycle = FakeLifecycleService()
        let manager = makeManager(
            inventory: FakeProcessInventory(results: [.success([])]),
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
        XCTAssertTrue(lifecycle.calls.contains("terminate:ExampleHelper"))
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
        cpu: Double = 0,
        memory: Double = 0,
        name: String
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: cpu,
            memoryMB: memory,
            command: name,
            elapsedTime: "00:10",
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }
}

private final class FakeLifecycleService: ProcessLifecycleServicing {
    var appExists = true
    var daemonResult = LifecycleBatchResult.notNeeded
    var agentLoadResult = LifecycleBatchResult.notNeeded
    var agentUnloadResult = LifecycleBatchResult.notNeeded
    var openResult = true
    var waitResult = true
    private(set) var calls: [String] = []

    func appBundleExists(at path: String) -> Bool {
        calls.append("exists")
        return appExists
    }

    func settleAfterProcessChange() async {
        calls.append("settle")
    }

    func terminateProcess(named name: String, forceIfStillRunning: Bool) async {
        calls.append("terminate:\(name)")
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        calls.append("running:\(name)")
        return false
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.unload")
        return agentUnloadResult
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.load")
        return agentLoadResult
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

private final class FakeProcessInventory: ProcessInventoryProviding {
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
    private(set) var sent: [SentSignal] = []

    init(alivePids: Set<Int32> = [], exitsOnKill: Bool = false) {
        self.alivePids = alivePids
        self.exitsOnKill = exitsOnKill
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(SentSignal(signal: signal, pid: pid))
        if signal == SIGKILL, exitsOnKill {
            alivePids.remove(pid)
        }
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        alivePids.contains(pid)
    }
}
