import XCTest
@testable import TaskScope

@MainActor
final class SettingsStoreTests: XCTestCase {
    private let suiteName = "TaskScope.SettingsStoreTests"
    private let key = "settings-tests"
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

    func testOlderPartialSettingsPreserveValidFieldsAndDefaultMissingFields() throws {
        let json = #"{"refreshIntervalSeconds":22,"processListLimit":120,"searchText":"Codex"}"#
        defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: key)

        let store = SettingsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(store.refreshIntervalSeconds, 22)
        XCTAssertEqual(store.processListLimit, 120)
        XCTAssertEqual(store.searchText, "Codex")
        XCTAssertFalse(store.enableNotifications)
        XCTAssertEqual(store.sortKey, .cpu)
    }

    func testLoadedAndRuntimeValuesAreClamped() throws {
        let json = #"{"refreshIntervalSeconds":-10,"processListLimit":9999,"cpuHighlightThreshold":0,"memHighlightThresholdMB":99999}"#
        defaults.set(try XCTUnwrap(json.data(using: .utf8)), forKey: key)
        let store = SettingsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(store.refreshIntervalSeconds, 2)
        XCTAssertEqual(store.processListLimit, 200)
        XCTAssertEqual(store.cpuHighlightThreshold, 1)
        XCTAssertEqual(store.memHighlightThresholdMB, 8192)

        store.refreshIntervalSeconds = 1_000
        store.processListLimit = -5
        XCTAssertEqual(store.refreshIntervalSeconds, 60)
        XCTAssertEqual(store.processListLimit, 10)
    }

    func testCorruptSettingsAreBackedUpBeforeDefaultsAreUsed() {
        let corrupt = Data([0xFF, 0x00, 0xAA])
        defaults.set(corrupt, forKey: key)

        let store = SettingsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }
}
