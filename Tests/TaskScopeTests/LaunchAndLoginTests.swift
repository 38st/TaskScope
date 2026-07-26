import XCTest
@testable import TaskScope

final class LaunchContextTests: XCTestCase {
    func testLoginAndAutomationLaunchesAreBackground() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(arguments: ["TaskScope"], launchedAsLoginItem: true),
            .background
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(arguments: ["TaskScope", "--automation"], launchedAsLoginItem: false),
            .background
        )
    }

    func testNormalLaunchIsInteractive() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(arguments: ["TaskScope"], launchedAsLoginItem: false),
            .interactive
        )
    }
}

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testRequiresApprovalIsDistinctAndActionable() {
        let service = FakeLoginItemService(state: .requiresApproval)
        let manager = LoginItemManager(service: service)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.state, .requiresApproval)
        XCTAssertTrue(manager.message?.contains("requires approval") == true)

        manager.openSystemSettings()
        XCTAssertEqual(service.openSettingsCount, 1)
    }

    func testObservedStateDrivesMessageAfterRegistration() {
        let service = FakeLoginItemService(state: .notRegistered)
        let manager = LoginItemManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(manager.state, .enabled)
        XCTAssertEqual(manager.message, "Launch at Login is on.")
    }
}

private final class FakeLoginItemService: LoginItemServicing {
    var state: LoginItemState
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(state: LoginItemState) {
        self.state = state
    }

    func register() throws {
        registerCount += 1
        state = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        state = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
