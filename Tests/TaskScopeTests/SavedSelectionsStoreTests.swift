import XCTest
@testable import TaskScope

@MainActor
final class SavedSelectionsStoreTests: XCTestCase {
    private let suiteName = "TaskScope.SavedSelectionsStoreTests"
    private let key = "saved-selections-tests"
    private var defaults: UserDefaults!

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

    func testRestartedProcessRecallsByExactExecutableCommand() {
        let store = makeStore()
        let original = process(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example")
        let restarted = process(pid: 99, command: original.command)
        XCTAssertTrue(store.save(name: "Example tools", processes: [original]))

        let result = store.resolve(store.selections[0], in: [restarted])

        XCTAssertEqual(result.matched, [restarted])
        XCTAssertTrue(result.unmatched.isEmpty)
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    func testNameFallbackOnlyMatchesWhenUnique() {
        let store = makeStore()
        let original = process(pid: 10, command: "Example")
        store.save(name: "Example", processes: [original])
        let first = process(pid: 20, command: "/one/Example")
        let second = process(pid: 21, command: "/two/Example")

        let ambiguous = store.resolve(store.selections[0], in: [first, second])
        let unique = store.resolve(store.selections[0], in: [first])

        XCTAssertTrue(ambiguous.matched.isEmpty)
        XCTAssertEqual(ambiguous.ambiguous.count, 1)
        XCTAssertEqual(unique.matched, [first])
    }

    func testDuplicateNamesAreRejectedAndRenamePersists() {
        let store = makeStore()
        store.save(name: "Editors", processes: [process(pid: 1, command: "Editor")])
        XCTAssertFalse(store.save(name: " editors ", processes: [process(pid: 2, command: "Other")]))
        XCTAssertTrue(store.rename(store.selections[0], to: "Development"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.selections.map(\.name), ["Development"])
    }

    func testLegacyPIDOnlySelectionIsPreservedAndMarkedUnsupported() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","pids":[42]}]
        """
        defaults.set(try XCTUnwrap(legacy.data(using: .utf8)), forKey: key)

        let store = makeStore()
        let result = store.resolve(store.selections[0], in: [process(pid: 42, command: "Replacement")])

        XCTAssertTrue(store.selections[0].isLegacyUnsupported)
        XCTAssertTrue(result.legacyUnsupported)
        XCTAssertTrue(result.matched.isEmpty)
    }

    func testCorruptSelectionsAreBackedUp() {
        let corrupt = Data([0xFF, 0x01])
        defaults.set(corrupt, forKey: key)

        let store = makeStore()

        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)
    }

    private func makeStore() -> SavedSelectionsStore {
        SavedSelectionsStore(userDefaults: defaults, key: key)
    }

    private func process(pid: Int32, command: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: "00:10",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }
}
