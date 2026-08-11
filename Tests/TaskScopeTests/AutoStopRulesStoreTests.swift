import XCTest
@testable import TaskScope

@MainActor
final class AutoStopRulesStoreTests: XCTestCase {
    nonisolated(unsafe) private var userDefaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopRulesStoreTests"
    private let key = "auto-stop-rules-tests"
    private let eventsKey = "auto-stop-events-tests"
    nonisolated(unsafe) private var currentDate: Date!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        currentDate = Date(timeIntervalSince1970: 1_000)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        currentDate = nil
        super.tearDown()
    }

    func testRulesPersistToConfiguredUserDefaults() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)

        XCTAssertTrue(store.add(rule))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rules, [rule])
    }

    func testRealRuntimeImmediatelyQualifiesAfterColdStart() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .kill)
        let process = appProcess(pid: 42, elapsed: "10:00")
        store.add(rule)

        var actions: [(AutoStopRule, AppProcess)] = []
        store.evaluate(runningProcesses: [process]) { actions.append(($0, $1)) }

        XCTAssertEqual(actions.map(\.0), [rule])
        XCTAssertEqual(actions.map(\.1.pid), [42])
    }

    func testOccurrenceUsesStableIdentityAndOnlyTriggersOnce() {
        let store = makeStore()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        let first = appProcess(pid: 42, elapsed: "02:00", startTime: "first")
        let replacement = appProcess(pid: 42, elapsed: "02:00", startTime: "second")
        var identities: [ProcessIdentity] = []

        store.evaluate(runningProcesses: [first]) { _, process in identities.append(process.identity) }
        store.evaluate(runningProcesses: [first]) { _, process in identities.append(process.identity) }
        store.evaluate(runningProcesses: [replacement]) { _, process in identities.append(process.identity) }

        XCTAssertEqual(identities, [first.identity, replacement.identity])
    }

    func testTwoPromptRulesQueueSeriallyAndDismissIsRecorded() async {
        let inventory = StubInventory(processes: [
            appProcess(pid: 41, command: "/Example", elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, command: "/Other", elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))

        await store.evaluateNow()

        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42])
        store.dismissCurrentPrompt()
        XCTAssertEqual(store.currentPrompt?.process.pid, 42)
        XCTAssertEqual(store.events.first?.outcome, .dismissed)

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [42])
    }

    func testTwoAutomaticActionsExecuteSeriallyAndReportOutcomes() async {
        let inventory = StubInventory(processes: [
            appProcess(pid: 41, command: "/Example", elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, command: "/Other", elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .kill))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .kill))
        var actionOrder: [Int32] = []
        store.start(cadence: 60) { _, process in
            actionOrder.append(process.pid)
            return process.pid == 41 ? .stopped : .rejected
        }

        await waitUntil { store.events.count == 2 }
        store.stop()

        XCTAssertEqual(actionOrder, [41, 42])
        XCTAssertEqual(Set(store.events.map(\.outcome)), Set([.stopped, .failed]))
    }

    func testLogOnlyPersistsBoundedVisibleEvents() async {
        let inventory = StubInventory(processes: [
            appProcess(pid: 41, elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory, eventLimit: 1)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent))

        await store.evaluateNow()

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].outcome, .logged)
        let reloaded = makeStore(inventory: inventory, eventLimit: 1)
        XCTAssertEqual(reloaded.events, store.events)
    }

    func testDuplicateNamesAreRejectedCaseInsensitivelyAndRuleCanBeEdited() {
        let store = makeStore()
        let first = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
        XCTAssertTrue(store.add(first))
        XCTAssertFalse(store.add(AutoStopRule(processName: " example ", runtimeMinutes: 2, action: .kill)))
        XCTAssertNotNil(store.validationError)

        var updated = first
        updated.runtimeMinutes = 8
        updated.action = .silent
        updated.isEnabled = false
        XCTAssertTrue(store.update(updated))

        XCTAssertEqual(store.rules, [updated])
        XCTAssertNil(store.validationError)
    }

    func testElapsedRuntimeParserSupportsPsFormats() {
        XCTAssertEqual(appProcess(pid: 1, elapsed: "01:02").runtimeSeconds, 62)
        XCTAssertEqual(appProcess(pid: 1, elapsed: "02:03:04").runtimeSeconds, 7_384)
        XCTAssertEqual(appProcess(pid: 1, elapsed: "2-03:04:05").runtimeSeconds, 183_845)
        XCTAssertNil(appProcess(pid: 1, elapsed: "invalid").runtimeSeconds)
    }

    func testCorruptRulesAndEventsAreBackedUp() {
        let corruptRules = Data([0xFF, 0x01])
        let corruptEvents = Data([0xFE, 0x02])
        userDefaults.set(corruptRules, forKey: key)
        userDefaults.set(corruptEvents, forKey: eventsKey)

        let store = makeStore()

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.recoveryMessages.count, 2)
        XCTAssertEqual(userDefaults.data(forKey: "\(key).corruptBackup"), corruptRules)
        XCTAssertEqual(userDefaults.data(forKey: "\(eventsKey).corruptBackup"), corruptEvents)
    }

    private func makeStore(
        inventory: any ProcessInventoryProviding = StubInventory(processes: []),
        eventLimit: Int = 200
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: userDefaults,
            key: key,
            eventsKey: eventsKey,
            inventory: inventory,
            eventLimit: eventLimit,
            now: { self.currentDate }
        )
    }

    private func appProcess(
        pid: Int32,
        command: String = "/Applications/Example.app/Example",
        elapsed: String,
        startTime: String = "start"
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 0,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: elapsed,
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private struct StubInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
