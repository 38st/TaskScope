import XCTest
@testable import TaskScope

@MainActor
final class AppCommandCoordinatorTests: XCTestCase {
    func testURLContractOnlyParsesNonDestructiveRefresh() throws {
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://refresh"))).get(),
            .refresh
        )
        for action in ["open", "stop", "quit"] {
            let url = try XCTUnwrap(URL(string: "taskscope://\(action)/GlobalProtect"))
            XCTAssertEqual(
                TaskScopeURLParser.command(from: url),
                .failure(.unsupportedAction(action))
            )
        }
    }

    func testURLContractRejectsUnsupportedRoutes() throws {
        let unsupported = try XCTUnwrap(URL(string: "taskscope://destroy/everything"))
        XCTAssertEqual(
            TaskScopeURLParser.command(from: unsupported),
            .failure(.unsupportedAction("destroy"))
        )
    }

    func testRefreshURLRejectsCredentialsPortPathQueryAndFragment() throws {
        let invalidURLs = [
            "taskscope://user@refresh",
            "taskscope://refresh:1234",
            "taskscope://refresh/path",
            "taskscope://refresh?source=test",
            "taskscope://refresh?",
            "taskscope://refresh#section",
            "taskscope://refresh#"
        ]

        for value in invalidURLs {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(
                TaskScopeURLParser.command(from: url),
                .failure(.invalidRefreshURL),
                value
            )
        }

        XCTAssertEqual(
            TaskScopeURLParser.command(
                from: try XCTUnwrap(URL(string: "taskscope://refresh/"))
            ),
            .failure(.invalidRefreshURL)
        )
        XCTAssertEqual(
            TaskScopeURLParser.command(
                from: try XCTUnwrap(URL(string: "taskscope://Refresh"))
            ),
            .failure(.unsupportedAction("Refresh"))
        )
    }

    func testLoggingSubsystemUsesConfiguredBundleIdentifier() {
        XCTAssertEqual(
            TaskScopeLogging.subsystem(bundleIdentifier: "com.example.TaskScope"),
            "com.example.TaskScope"
        )
        XCTAssertEqual(TaskScopeLogging.subsystem(bundleIdentifier: nil), "TaskScope")
    }

    func testColdLaunchCommandIsDeliveredExactlyOnceAfterInstall() async {
        let bus = AppCommandBus()
        let pending = Task { await bus.submit(.openPreset("Example")) }
        await Task.yield()
        var received: [TaskScopeCommand] = []

        bus.install { command in
            received.append(command)
            return TaskScopeCommandResult(status: .completed, message: "done")
        }

        let result = await pending.value
        XCTAssertEqual(received, [.openPreset("Example")])
        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "done"))
    }

    func testColdLaunchCommandsDrainInSubmissionOrder() async {
        let bus = AppCommandBus()
        let first = Task { await bus.submit(.openPreset("First")) }
        await Task.yield()
        let second = Task { await bus.submit(.openPreset("Second")) }
        await Task.yield()
        var received: [TaskScopeCommand] = []

        bus.install { command in
            received.append(command)
            await Task.yield()
            return TaskScopeCommandResult(status: .completed, message: "done")
        }

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(received, [.openPreset("First"), .openPreset("Second")])
    }

    func testCoordinatorReturnsMeaningfulMissingPresetResult() async {
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [] }
        )

        let missing = await coordinator.perform(.openPreset("Missing"))

        XCTAssertEqual(missing.status, .rejected)
        XCTAssertTrue(missing.message.contains("Missing"))
    }

    func testExplicitRefreshPublishesJoinedSilentRefreshResult() async {
        let inventory = CoordinatorBlockingInventory()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [] }
        )

        let silentRefresh = Task {
            await manager.refreshWatchedStatus(showMessage: false)
        }
        await inventory.waitForLoad()
        let explicitRefresh = Task { await coordinator.perform(.refresh) }
        await Task.yield()

        XCTAssertEqual(manager.message, "Idle.")
        await inventory.finish()
        await silentRefresh.value
        let result = await explicitRefresh.value

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.message, manager.message)
        XCTAssertNotEqual(result.message, "Idle.")
    }

    func testEntityCommandRejectsReplacementPresetWithSameDisplayName() async {
        let selectedID = UUID()
        let replacement = WatchedAppPreset(
            id: UUID(),
            displayName: "Example",
            mainProcessName: "ReplacementProcess",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Replacement.app"
        )
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [replacement] }
        )

        let result = await coordinator.perform(
            .stopPresetEntity(
                WatchedPresetCommandTarget(id: selectedID, displayName: "Example")
            )
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("Example"))
        XCTAssertNil(manager.lifecycleReport)
    }

    func testStartupVerificationRejectsAllExplicitCommands() async {
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [.globalProtect] },
            allowsCommands: { false }
        )

        for command in [
            TaskScopeCommand.refresh,
            .openPreset("GlobalProtect"),
            .stopPreset("GlobalProtect")
        ] {
            let result = await coordinator.perform(command)
            XCTAssertEqual(result.status, .rejected)
            XCTAssertTrue(result.message.contains("startup verification"))
        }
    }

    func testURLHandlerNotifiesLaunchPolicyBeforeDispatchingCommand() async throws {
        var events: [String] = []
        let handler = URLSchemeHandler(
            submitCommand: { command in
                events.append("dispatch:\(command)")
                return TaskScopeCommandResult(status: .completed, message: "done")
            },
            willHandleCommand: { command in
                events.append("prepare:\(command)")
            }
        )

        let result = await handler.handle(
            try XCTUnwrap(URL(string: "taskscope://refresh"))
        )

        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "done"))
        XCTAssertEqual(events, ["prepare:refresh", "dispatch:refresh"])
    }
}

private struct EmptyInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success([])
    }
}

private actor CoordinatorBlockingInventory: ProcessInventoryProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        didStart = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return .success([])
    }

    func waitForLoad() async {
        guard !didStart else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct NoopLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}
