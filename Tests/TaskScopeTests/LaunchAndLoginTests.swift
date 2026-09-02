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

    /// An interactive launch that is not yet active when the cold-open grace
    /// period ends keeps its interactive intent and presents on the next
    /// activation; it is never demoted to an accessory app.
    func testInactiveInteractiveLaunchPresentsOnNextActivationWithoutDemotion() {
        XCTAssertEqual(
            TaskScopeInteractiveLaunchPresentation.resolve(isActive: false),
            .presentOnNextActivation
        )
        XCTAssertEqual(
            TaskScopeInteractiveLaunchPresentation.resolve(isActive: true),
            .presentNow
        )
        XCTAssertFalse(TaskScopeInteractiveLaunchPresentation.presentOnNextActivation.demotesToAccessory)
        XCTAssertFalse(TaskScopeInteractiveLaunchPresentation.presentNow.demotesToAccessory)
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

    func testRefreshObservesApprovalGrantedInSystemSettings() {
        let service = FakeLoginItemService(state: .requiresApproval)
        let manager = LoginItemManager(service: service)

        service.state = .enabled
        manager.refresh()

        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(manager.message, "Launch at Login is on.")
    }

    /// A `.notFound` registration (bundle moved or replaced) can only be
    /// cleared by an unregister attempt; the thrown error must be surfaced.
    func testDisablingAnUnavailableRegistrationStillAttemptsUnregisterAndSurfacesTheError() {
        let service = FakeLoginItemService(state: .notFound)
        let manager = LoginItemManager(service: service)

        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)

        let failing = FakeLoginItemService(state: .notFound)
        failing.unregisterError = LoginItemTestError.refused
        let failingManager = LoginItemManager(service: failing)

        failingManager.setEnabled(false)

        XCTAssertEqual(failing.unregisterCount, 1)
        XCTAssertTrue(failingManager.message?.contains("Could not update Launch at Login") == true)
        XCTAssertTrue(failingManager.message?.contains("The system refused the change.") == true)
    }

    func testActivationRefreshUpdatesLoginAndNotificationState() async {
        var events: [String] = []

        await TaskScopeExternalStateRefresh.perform(
            refreshLoginItem: { events.append("login") },
            refreshNotificationAuthorization: { events.append("notifications") }
        )

        XCTAssertEqual(events, ["login", "notifications"])
    }
}

private enum LoginItemTestError: LocalizedError {
    case refused

    var errorDescription: String? {
        "The system refused the change."
    }
}

private final class FakeLoginItemService: LoginItemServicing {
    var state: LoginItemState
    var unregisterError: Error?
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
        if let unregisterError {
            throw unregisterError
        }
        state = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
