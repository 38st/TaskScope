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
        XCTAssertFalse(store.keepGlobalProtectOff)
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
        store.memHighlightThresholdMB = 10
        XCTAssertEqual(store.refreshIntervalSeconds, 60)
        XCTAssertEqual(store.processListLimit, 10)
        XCTAssertEqual(store.memHighlightThresholdMB, SettingsStore.memoryThresholdRange.lowerBound)
    }

    /// The slider's grid must be able to reach the default value.
    func testMemorySliderGridContainsTheDefault() {
        let defaultValue = SettingsStore(userDefaults: defaults, key: key).memHighlightThresholdMB
        let range = SettingsStore.memoryThresholdRange
        let step = SettingsStore.memoryThresholdStep

        XCTAssertEqual(defaultValue, 1024)
        XCTAssertTrue(range.contains(defaultValue))
        XCTAssertEqual((defaultValue - range.lowerBound).truncatingRemainder(dividingBy: step), 0)
    }

    /// Search text is typed one character at a time; each keystroke used to
    /// rewrite UserDefaults. The write is debounced and can be flushed.
    func testSearchTextPersistenceIsDebounced() async throws {
        let store = SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0.05)

        store.searchText = "a"
        store.searchText = "ab"
        XCTAssertNil(persistedSearchText(), "no write may happen while typing continues")

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(persistedSearchText(), "ab")

        store.searchText = "abc"
        store.flushPendingWrites()
        XCTAssertEqual(persistedSearchText(), "abc")
    }

    private func persistedSearchText() -> String? {
        guard let data = defaults.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["searchText"] as? String
    }

    func testCorruptSettingsAreBackedUpBeforeDefaultsAreUsed() {
        let corrupt = Data([0xFF, 0x00, 0xAA])
        defaults.set(corrupt, forKey: key)

        let store = SettingsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testFirstCorruptSettingsBackupIsNotOverwrittenByLaterCorruption() {
        let first = Data([0xFF, 0x01])
        let second = Data([0xFE, 0x02])
        defaults.set(first, forKey: key)
        _ = SettingsStore(userDefaults: defaults, key: key)

        defaults.set(second, forKey: key)
        _ = SettingsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), first)
        XCTAssertEqual(defaults.data(forKey: key), second)
    }

    func testCorruptSettingsCannotPersistUntilExplicitReset() {
        let corrupt = Data([0xFF, 0x03])
        defaults.set(corrupt, forKey: key)
        let store = SettingsStore(userDefaults: defaults, key: key)

        store.refreshIntervalSeconds = 22
        store.enableNotifications = true

        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.data(forKey: key), corrupt)

        store.resetAfterCorruption()

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.recoveryMessage)
        XCTAssertNotEqual(defaults.data(forKey: key), corrupt)
        let relaunched = SettingsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(relaunched.refreshIntervalSeconds, 22)
        XCTAssertTrue(relaunched.enableNotifications)
    }

    func testKeepGlobalProtectOffPersistsAndDefaultsOffForOlderSettings() throws {
        let oldJSON = #"{"schemaVersion":2,"refreshIntervalSeconds":10}"#
        defaults.set(try XCTUnwrap(oldJSON.data(using: .utf8)), forKey: key)
        let migrated = SettingsStore(userDefaults: defaults, key: key)
        XCTAssertFalse(migrated.keepGlobalProtectOff)

        migrated.keepGlobalProtectOff = true
        let relaunched = SettingsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(relaunched.keepGlobalProtectOff)
    }
}
