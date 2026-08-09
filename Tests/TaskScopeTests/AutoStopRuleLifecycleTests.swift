import XCTest
@testable import TaskScope

/// Covers the rule-lifecycle invariants around the auto-stop engine: an action must
/// fire only while its rule is still active, a retired rule must take its prompts
/// with it, and a stop that was never actually attempted must not be treated as
/// permanently handled.
@MainActor
final class AutoStopRuleLifecycleTests: XCTestCase {
    private let suiteName = "TaskScope.AutoStopRuleLifecycleTests"
    private let key = "auto-stop-rules-lifecycle-tests"
    private let eventsKey = "auto-stop-events-lifecycle-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Disabling a rule while its prompt is on screen must retire that prompt.
    /// `update(_:)` cleared `handledOccurrences` but left `pendingPrompts`, so the
    /// alert for a switched-off rule stayed live and "Stop Now" still killed under it.
    func testDisablingARuleRetiresItsPendingPrompt() async {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
        store.add(rule)
        let stored = store.rules[0]

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1, "precondition: a prompt is queued")

        store.setEnabled(false, for: stored)

        XCTAssertTrue(store.pendingPrompts.isEmpty, "a disabled rule must not keep a live prompt")
        XCTAssertNil(store.currentPrompt)
    }

    /// Re-enabling must not resurrect an occurrence the user already disposed of by
    /// disabling the rule: the prompt is gone, so nothing should be actionable until
    /// the threshold is crossed again by a genuinely new evaluation.
    func testTogglingARuleOffAndOnDoesNotLeaveAStalePrompt() async {
        let store = makeStore()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        let stored = store.rules[0]

        await store.evaluateNow()
        store.setEnabled(false, for: stored)
        store.setEnabled(true, for: store.rules[0])

        XCTAssertTrue(
            store.pendingPrompts.isEmpty,
            "toggling must not leave a duplicate of the prompt it already retired"
        )
    }

    /// A `.kill` rule deleted while its handler is in flight must not go on acting.
    /// `evaluate` snapshots the active rules once and then awaits per process, so
    /// the rule has to be re-checked after the suspension.
    func testRuleDeletedWhileTheStopIsInFlightRecordsNoOutcome() async {
        let store = makeStore(processes: [
            appProcess(pid: 41, elapsed: "10:00"),
            appProcess(pid: 42, elapsed: "10:00")
        ])
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .kill))
        let stored = store.rules[0]

        var handled: [Int32] = []
        store.start(cadence: 3_600) { process in
            handled.append(process.pid)
            // Delete the rule from inside the first in-flight action, exactly as a
            // Settings tap landing during the suspension would.
            store.remove(stored)
            return .stopped
        }

        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(handled, [41], "the second process must not be signalled under a deleted rule")
        XCTAssertTrue(
            store.events.isEmpty,
            "no outcome may be recorded against a rule the user already removed"
        )
    }

    /// A stop that never happened (nothing was signalled) must stay retryable, and
    /// must not flood the log with one failure per tick while it keeps failing.
    func testUnattemptedStopIsRetriedButLoggedOnlyOnce() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .kill))

        var attempts = 0
        store.start(cadence: 3_600) { _ in
            attempts += 1
            return .rejected
        }

        // `start` intentionally evaluates once before sleeping. Synchronize with that
        // real engine tick so the three explicit evaluations below cannot race it.
        for _ in 0..<100 where attempts == 0 || store.events.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(attempts, 1, "precondition: the engine performs its initial evaluation")
        XCTAssertEqual(store.events.count, 1, "precondition: the first failure is recorded")
        attempts = 0

        await store.evaluateNow()
        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 3, "a stop that was never attempted must be retried on later ticks")
        XCTAssertEqual(
            store.events.count,
            1,
            "a persistent failure must be logged once, not once per tick"
        )
        XCTAssertEqual(store.events.first?.outcome, .failed)
    }

    /// The counterpart: once the stop succeeds, the occurrence is done.
    func testSuccessfulStopIsRecordedAndNotRetried() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .kill))

        var attempts = 0
        store.start(cadence: 3_600) { _ in
            attempts += 1
            return .stopped
        }

        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.events.map(\.outcome), [.stopped])
    }

    // MARK: - Helpers

    private func makeStore(
        processes: [AppProcess] = [appProcess(pid: 41, elapsed: "10:00")]
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: key,
            eventsKey: eventsKey,
            inventory: StubInventory(processes: processes),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

}

private func appProcess(pid: Int32, elapsed: String) -> AppProcess {
    AppProcess(
        pid: pid,
        parentPID: 1,
        cpu: 1,
        memoryMB: 1,
        command: "Example",
        elapsedTime: elapsed,
        startTime: "start-\(pid)",
        netInKB: nil,
        netOutKB: nil,
        diskReadBlocks: nil,
        diskWriteBlocks: nil
    )
}

private struct StubInventory: ProcessInventoryProviding {
    let processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
