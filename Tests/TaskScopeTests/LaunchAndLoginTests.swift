import XCTest
@testable import TaskScope

final class LaunchContextTests: XCTestCase {
    func testLoginAndAutomationLaunchesAreBackground() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope"],
                    launchedAsLoginItem: true,
                    receivedOpenURL: false
                )
            ),
            .loginItem
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope", "--automation"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: false
                )
            ),
            .automation
        )
    }

    func testNormalLaunchIsInteractive() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: false
                )
            ),
            .interactive
        )
    }

    func testStartupVerificationIsIsolatedFromRuntimeAndCommands() {
        let context = TaskScopeLaunchContext.detect(
            TaskScopeLaunchSignal(
                arguments: ["TaskScope", "--verify-startup"],
                launchedAsLoginItem: false,
                receivedOpenURL: false
            )
        )

        XCTAssertEqual(context, .startupVerification)
        XCTAssertTrue(context.suppressesAutomaticWindowPresentation)
        XCTAssertFalse(context.allowsExplicitCommands)
        XCTAssertFalse(context.performsRuntimeBootstrap)
    }

    func testColdURLLaunchIsBackgroundButStillAcceptsItsExplicitCommand() {
        let context = TaskScopeLaunchContext.detect(
            TaskScopeLaunchSignal(
                arguments: ["TaskScope"],
                launchedAsLoginItem: false,
                receivedOpenURL: true
            )
        )

        XCTAssertEqual(context, .urlAutomation)
        XCTAssertTrue(context.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(context.allowsExplicitCommands)
    }

    func testInteractiveLaunchAloneAllowsAutomaticWindowPresentation() {
        XCTAssertFalse(TaskScopeLaunchContext.interactive.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.loginItem.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.automation.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.urlAutomation.suppressesAutomaticWindowPresentation)
    }

    func testBackgroundArgumentsTakePriorityOverURLSignal() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope", "--background"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: true
                )
            ),
            .automation
        )
    }

    func testLaunchResolutionWaitsUntilFinalCallbackBeforePromotingInteractiveLaunch() {
        let interactiveSignal = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: false
        )

        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: .pending,
                signal: interactiveSignal,
                finalizeInteractiveLaunch: false
            ),
            .pending
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: .pending,
                signal: interactiveSignal,
                finalizeInteractiveLaunch: true
            ),
            .interactive
        )
    }

    func testLaunchResolutionNeverPromotesURLContextWhenEventIsNoLongerCurrent() {
        let urlSignal = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: true
        )
        let noCurrentEvent = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: false
        )
        let detectedURL = TaskScopeLaunchContext.resolve(
            current: .pending,
            signal: urlSignal,
            finalizeInteractiveLaunch: false
        )

        XCTAssertEqual(detectedURL, .urlAutomation)
        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: detectedURL,
                signal: noCurrentEvent,
                finalizeInteractiveLaunch: true
            ),
            .urlAutomation
        )
    }

    func testIncomingURLOnlyConvertsStartupLaunchToBackground() {
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingURL(
                current: .interactive,
                phase: .starting
            ),
            .urlAutomation
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingURL(
                current: .interactive,
                phase: .running
            ),
            .interactive
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingURL(
                current: .loginItem,
                phase: .running
            ),
            .loginItem
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingURL(
                current: .startupVerification,
                phase: .starting
            ),
            .startupVerification
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
