import XCTest
import UserNotifications
@testable import TaskScope

final class NotificationBaselineTests: XCTestCase {
    func testFirstObservationAndDisabledDeliveryOnlyRebaseline() {
        var baseline = ProcessNotificationBaseline()

        let first = baseline.transitions(to: ["Example"], canNotify: true)
        let disabled = baseline.transitions(to: ["Other"], canNotify: false)
        let enabledAgain = baseline.transitions(to: ["Other"], canNotify: true)

        XCTAssertTrue(first.started.isEmpty)
        XCTAssertTrue(first.stopped.isEmpty)
        XCTAssertTrue(disabled.started.isEmpty)
        XCTAssertTrue(disabled.stopped.isEmpty)
        XCTAssertTrue(enabledAgain.started.isEmpty)
        XCTAssertTrue(enabledAgain.stopped.isEmpty)
    }

    func testPreferenceChangeCanRebaselineWithoutFalseTransition() {
        var baseline = ProcessNotificationBaseline()
        baseline.rebaseline(["Allowed"])

        baseline.rebaseline(["DifferentEligibleSet"])
        let transition = baseline.transitions(to: ["DifferentEligibleSet"], canNotify: true)

        XCTAssertTrue(transition.started.isEmpty)
        XCTAssertTrue(transition.stopped.isEmpty)
    }

    func testPhysicalTransitionsAreDiffedAfterBaseline() {
        var baseline = ProcessNotificationBaseline()
        baseline.rebaseline(["Old", "Shared"])

        let transition = baseline.transitions(to: ["New", "Shared"], canNotify: true)

        XCTAssertEqual(transition.started, ["New"])
        XCTAssertEqual(transition.stopped, ["Old"])
    }

    @MainActor
    func testAuthorizationMappingAndDeliveryEligibilityAreExplicit() {
        XCTAssertEqual(
            NotificationService.authorizationState(for: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(NotificationService.authorizationState(for: .denied), .denied)
        XCTAssertEqual(NotificationService.authorizationState(for: .authorized), .authorized)
        XCTAssertEqual(NotificationService.authorizationState(for: .provisional), .provisional)
        XCTAssertTrue(NotificationService.canDeliver(for: .authorized))
        XCTAssertTrue(NotificationService.canDeliver(for: .provisional))
        XCTAssertFalse(NotificationService.canDeliver(for: .denied))
        XCTAssertFalse(NotificationService.canDeliver(for: .notDetermined))
    }

    func testForegroundPresentationUsesBannerWithoutSound() {
        let options = NotificationService.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertFalse(options.contains(.sound))
    }
}
