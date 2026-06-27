import XCTest
@testable import TaskScope

@MainActor
final class AutoStopRulesStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopRulesStoreTests"
    private let key = "auto-stop-rules-tests"
    private var currentDate: Date!

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

        store.add(rule)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rules, [rule])
    }

    func testEvaluateTriggersAfterRuntimeThreshold() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 2, action: .kill)
        let process = appProcess(pid: 42, command: "/Applications/Example.app/Example")
        store.add(rule)

        var actions: [(AutoStopRule, AppProcess)] = []
        store.evaluate(runningProcesses: [process]) { actions.append(($0, $1)) }
        XCTAssertTrue(actions.isEmpty)

        currentDate = currentDate.addingTimeInterval(119)
        store.evaluate(runningProcesses: [process]) { actions.append(($0, $1)) }
        XCTAssertTrue(actions.isEmpty)

        currentDate = currentDate.addingTimeInterval(1)
        store.evaluate(runningProcesses: [process]) { actions.append(($0, $1)) }

        XCTAssertEqual(actions.map(\.0), [rule])
        XCTAssertEqual(actions.map(\.1.pid), [42])
    }

    func testEvaluateClearsTrackingForStoppedProcesses() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 2, action: .prompt)
        let process = appProcess(pid: 42, command: "/Applications/Example.app/Example")
        store.add(rule)

        var actions: [AutoStopRule] = []
        store.evaluate(runningProcesses: [process]) { rule, _ in actions.append(rule) }
        store.evaluate(runningProcesses: []) { rule, _ in actions.append(rule) }

        currentDate = currentDate.addingTimeInterval(120)
        store.evaluate(runningProcesses: [process]) { rule, _ in actions.append(rule) }

        XCTAssertTrue(actions.isEmpty)
    }

    func testEvaluateIgnoresNonMatchingProcessesCaseInsensitivelyMatchesNames() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "example", runtimeMinutes: 1, action: .silent)
        let matching = appProcess(pid: 42, command: "/Applications/Example.app/Example")
        let nonMatching = appProcess(pid: 43, command: "/Applications/Other.app/Other")
        store.add(rule)

        var actions: [AppProcess] = []
        store.evaluate(runningProcesses: [matching, nonMatching]) { _, process in actions.append(process) }

        currentDate = currentDate.addingTimeInterval(60)
        store.evaluate(runningProcesses: [matching, nonMatching]) { _, process in actions.append(process) }

        XCTAssertEqual(actions.map(\.pid), [42])
    }

    private func makeStore() -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: userDefaults, key: key, now: { self.currentDate })
    }

    private func appProcess(pid: Int32, command: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 0,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: "",
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }
}
