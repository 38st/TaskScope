import XCTest
@testable import TaskScope

@MainActor
final class AppCommandCoordinatorTests: XCTestCase {
    func testURLContractParsesSupportedCommands() throws {
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://refresh"))).get(),
            .refresh
        )
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://open/GlobalProtect"))).get(),
            .openPreset("GlobalProtect")
        )
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://stop/My%20App"))).get(),
            .stopPreset("My App")
        )
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://quit"))).get(),
            .quitApplication
        )
    }

    func testURLContractRejectsMissingTargetsAndUnsupportedRoutes() throws {
        let missing = try XCTUnwrap(URL(string: "taskscope://open"))
        XCTAssertEqual(
            TaskScopeURLParser.command(from: missing),
            .failure(.missingTarget("open"))
        )

        let unsupported = try XCTUnwrap(URL(string: "taskscope://destroy/everything"))
        XCTAssertEqual(
            TaskScopeURLParser.command(from: unsupported),
            .failure(.unsupportedAction("destroy"))
        )
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

    func testCoordinatorReturnsMeaningfulMissingPresetAndQuitResults() async {
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        var didQuit = false
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [] },
            terminateApplication: { didQuit = true }
        )

        let missing = await coordinator.perform(.openPreset("Missing"))
        let quit = await coordinator.perform(.quitApplication)

        XCTAssertEqual(missing.status, .rejected)
        XCTAssertTrue(missing.message.contains("Missing"))
        XCTAssertEqual(quit.status, .completed)
        XCTAssertTrue(didQuit)
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
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async {}
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}
