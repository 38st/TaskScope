import XCTest
@testable import TaskScope

@MainActor
final class ActivityMonitorCoordinatorTests: XCTestCase {
    func testSuccessfulHandoffOpensAndSelectsRequestedPID() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true])
        let selector = FakeActivityMonitorProcessSelector(results: [.selected])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(pid: 42)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(selector.requestedPIDs, [42])
    }

    func testMissingProcessDoesNotOpenActivityMonitor() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [false])
        let selector = FakeActivityMonitorProcessSelector(results: [])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(pid: 77)

        XCTAssertEqual(outcome, .missingProcess)
        XCTAssertEqual(opener.openCount, 0)
        XCTAssertTrue(selector.requestedPIDs.isEmpty)
        XCTAssertTrue(outcome.message(for: 77).contains("no longer running"))
    }

    func testLaunchFailureReturnsTypedOutcome() async {
        let opener = FakeActivityMonitorOpener(error: TestOpenError.failed)
        let checker = FakeActivityMonitorProcessChecker(results: [true])
        let selector = FakeActivityMonitorProcessSelector(results: [])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(pid: 88)

        XCTAssertEqual(outcome, .appLaunchFailed("Activity Monitor launch failed."))
        XCTAssertTrue(outcome.message(for: 88).contains("Could not open Activity Monitor"))
        XCTAssertTrue(selector.requestedPIDs.isEmpty)
    }

    func testAutomationDenialStopsRetryingAndProvidesRecoveryInstructions() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.automationDenied("Not authorized to send Apple events.")]
        )
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(pid: 99)

        XCTAssertEqual(
            outcome,
            .automationDenied("Not authorized to send Apple events.")
        )
        XCTAssertEqual(selector.requestedPIDs, [99])
        XCTAssertTrue(outcome.message(for: 99).contains("Privacy & Security > Automation"))
    }

    func testReadinessIsRetriedUntilSelectionSucceeds() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.notReady, .failed("Application is not ready."), .selected]
        )
        var sleepDurations: [UInt64] = []
        let coordinator = ActivityMonitorCoordinator(
            opener: opener,
            processChecker: checker,
            selector: selector,
            maximumSelectionAttempts: 3,
            retryDelayNanoseconds: 123,
            sleep: { sleepDurations.append($0) }
        )

        let outcome = await coordinator.openAndSelect(pid: 1234)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(selector.requestedPIDs, [1234, 1234, 1234])
        XCTAssertEqual(sleepDurations, [123, 123])
    }

    func testRetryBudgetProducesTimeoutWithLastError() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.notReady, .failed("Activity Monitor was busy.")]
        )
        let coordinator = makeCoordinator(
            opener: opener,
            checker: checker,
            selector: selector,
            maximumAttempts: 2
        )

        let outcome = await coordinator.openAndSelect(pid: 321)

        XCTAssertEqual(outcome, .timedOut(lastError: "Activity Monitor was busy."))
        XCTAssertEqual(selector.requestedPIDs, [321, 321])
        XCTAssertTrue(outcome.message(for: 321).contains("retry timed out"))
    }

    func testProcessEndingDuringRetryReturnsMissingProcess() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, false])
        let selector = FakeActivityMonitorProcessSelector(results: [.notReady])
        let coordinator = makeCoordinator(
            opener: opener,
            checker: checker,
            selector: selector,
            maximumAttempts: 3
        )

        let outcome = await coordinator.openAndSelect(pid: 654)

        XCTAssertEqual(outcome, .missingProcess)
        XCTAssertEqual(selector.requestedPIDs, [654])
    }

    private func makeCoordinator(
        opener: FakeActivityMonitorOpener,
        checker: FakeActivityMonitorProcessChecker,
        selector: FakeActivityMonitorProcessSelector,
        maximumAttempts: Int = 3
    ) -> ActivityMonitorCoordinator {
        ActivityMonitorCoordinator(
            opener: opener,
            processChecker: checker,
            selector: selector,
            maximumSelectionAttempts: maximumAttempts,
            retryDelayNanoseconds: 0,
            sleep: { _ in }
        )
    }
}

@MainActor
private final class FakeActivityMonitorOpener: ActivityMonitorOpening {
    private(set) var openCount = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func open() async throws {
        openCount += 1
        if let error {
            throw error
        }
    }
}

@MainActor
private final class FakeActivityMonitorProcessChecker: ActivityMonitorProcessChecking {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func processExists(pid: Int32) -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}

@MainActor
private final class FakeActivityMonitorProcessSelector: ActivityMonitorProcessSelecting {
    private var results: [ActivityMonitorSelectionAttempt]
    private(set) var requestedPIDs: [Int32] = []

    init(results: [ActivityMonitorSelectionAttempt]) {
        self.results = results
    }

    func select(pid: Int32) -> ActivityMonitorSelectionAttempt {
        requestedPIDs.append(pid)
        return results.isEmpty ? .notReady : results.removeFirst()
    }
}

private enum TestOpenError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Activity Monitor launch failed."
    }
}
