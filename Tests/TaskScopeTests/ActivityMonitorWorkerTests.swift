import XCTest
@testable import TaskScope

@MainActor
final class ActivityMonitorWorkerTests: XCTestCase {
    func testOverlappingAttemptsRetainOriginalSettingsUntilRestoration() async {
        let table = WorkerTableFixture()
        let started = expectation(description: "first worker selection started")
        let release = DispatchSemaphore(value: 0)
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, pid, _, state in
                if pid == 1 {
                    started.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
                return table.select(pid: pid, existing: state)
            },
            restoration: { table.restore($0) }
        )
        let first = Task { await worker.selectOrPrepare(applicationPID: 42, targetPID: 1, processName: nil) }
        await fulfillment(of: [started], timeout: 2)
        let submitted = expectation(description: "second selection submitted")
        let second = Task {
            submitted.fulfill()
            return await worker.selectOrPrepare(applicationPID: 42, targetPID: 2, processName: nil)
        }
        await fulfillment(of: [submitted], timeout: 2)
        release.signal()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome.preparedState?.searchValue, "original search")
        XCTAssertEqual(secondOutcome.preparedState?.searchValue, "original search")
        XCTAssertEqual(table.search, "temporary 2")

        // The first handoff's timer may already have been queued.
        await worker.restore(generation: firstOutcome.generation)
        XCTAssertEqual(table.search, "temporary 2")
        await worker.restore(generation: secondOutcome.generation)
        XCTAssertEqual(table.search, "original search")
        XCTAssertEqual(table.restoreCount, 1)
        worker.restoreNow()
        XCTAssertEqual(table.restoreCount, 1)
    }

    func testSynchronousShutdownRestoresStateFromAnInFlightAttempt() async {
        let table = WorkerTableFixture()
        let started = expectation(description: "worker selection started")
        let release = DispatchSemaphore(value: 0)
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, pid, _, state in
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return table.select(pid: pid, existing: state)
            },
            restoration: { table.restore($0) }
        )
        let attempt = Task { await worker.selectOrPrepare(applicationPID: 42, targetPID: 1, processName: nil) }
        await fulfillment(of: [started], timeout: 2)
        // The worker has not returned state to the main actor yet.
        release.signal()
        worker.restoreNow()
        _ = await attempt.value
        XCTAssertEqual(table.search, "original search")
        XCTAssertEqual(table.restoreCount, 1)
    }
}

private final class WorkerTableFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "original search"
    private var restorations = 0
    var search: String { lock.withLock { value } }
    var restoreCount: Int { lock.withLock { restorations } }

    func select(pid: Int32, existing: ActivityMonitorPreparedTableState?) -> ActivityMonitorAccessibilityWorker.Outcome {
        lock.withLock {
            var state = existing ?? ActivityMonitorPreparedTableState(searchValue: value)
            state.searchWasChanged = true
            state.searchValueSet = "temporary \(pid)"
            value = state.searchValueSet
            return .init(attempt: .notReady, preparedState: state)
        }
    }

    func restore(_ state: ActivityMonitorPreparedTableState) {
        lock.withLock {
            value = state.searchValue
            restorations += 1
        }
    }
}
