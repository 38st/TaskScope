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
            try TaskScopeURLParser.command(
                from: XCTUnwrap(URL(string: "taskscope://refresh/"))
            ).get(),
            .refresh
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
        let pending = Task { await AppCommandBus.shared.submit(.openPreset("Example")) }
        await Task.yield()
        var received: [TaskScopeCommand] = []

        AppCommandBus.shared.install { command in
            received.append(command)
            return TaskScopeCommandResult(status: .completed, message: "done")
        }

        let result = await pending.value
        XCTAssertEqual(received, [.openPreset("Example")])
        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "done"))
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

private struct NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct NoopLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}
