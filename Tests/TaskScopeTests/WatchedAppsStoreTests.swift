import XCTest
@testable import TaskScope

@MainActor
final class WatchedAppsStoreTests: XCTestCase {
    private let suiteName = "TaskScope.WatchedAppsStoreTests"
    private let key = "watched-presets-tests"
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

    func testCorruptPayloadIsBackedUpAndCannotBeOverwrittenByMutation() {
        let corrupt = Data([0xFE, 0xED])
        defaults.set(corrupt, forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(store.persistenceIssue)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)

        _ = store.add(validPreset(name: "Example"))
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testFirstPresetBackupSurvivesASecondCorruptLaunch() {
        let first = Data([0xFE, 0x01])
        let second = Data([0xFE, 0x02])
        defaults.set(first, forKey: key)
        _ = WatchedAppsStore(userDefaults: defaults, key: key)

        defaults.set(second, forKey: key)
        _ = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), first)
        XCTAssertEqual(defaults.data(forKey: key), second)
    }

    func testExplicitResetAfterCorruptionAllowsPersistence() throws {
        defaults.set(Data([0xFE, 0xED]), forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        store.resetAfterCorruption()

        let persisted = try JSONDecoder().decode(
            [WatchedAppPreset].self,
            from: XCTUnwrap(defaults.data(forKey: key))
        )
        XCTAssertEqual(persisted, [.globalProtect])
        XCTAssertNil(store.persistenceIssue)
    }

    func testValidationTrimsFieldsAndRejectsSemanticDuplicates() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var preset = validPreset(name: " Example ")
        preset.mainProcessName = " ExampleProcess "
        preset.appPath = " /Applications/Example.app "

        XCTAssertTrue(store.add(preset))
        XCTAssertEqual(store.presets[0].displayName, "Example")
        XCTAssertEqual(store.presets[0].mainProcessName, "ExampleProcess")
        XCTAssertEqual(store.presets[0].appPath, "/Applications/Example.app")
        XCTAssertFalse(store.add(validPreset(name: "example")))
        XCTAssertNotNil(store.validationError)
    }

    func testDirectoryOnlyAppPathAndInvalidPortAreRejected() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var directory = validPreset(name: "Directory")
        directory.appPath = "/Applications/"
        XCTAssertFalse(store.add(directory))

        var invalidPort = validPreset(name: "Port")
        invalidPort.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "daemon",
                plistPath: "/Library/LaunchDaemons/daemon.plist",
                processName: "daemon",
                servicePort: 70_000
            )
        ]
        XCTAssertFalse(store.add(invalidPort))
    }

    func testImportRejectsRepeatedIDsWithinTheSamePayload() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        let first = validPreset(name: "First")
        var repeatedID = validPreset(name: "Second")
        repeatedID.id = first.id

        let result = store.importPresets([first, repeatedID])

        XCTAssertEqual(result, .init(importedCount: 1, rejectedCount: 1))
        XCTAssertEqual(store.presets.map(\.displayName), ["First"])
        XCTAssertEqual(Set(store.presets.map(\.id)).count, store.presets.count)
    }

    func testCustomPrivilegedDaemonsAndProcessRoleOverlapsAreRejected() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var daemon = validPreset(name: "Privileged")
        daemon.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "com.example.daemon",
                plistPath: "/Library/LaunchDaemons/com.example.daemon.plist",
                processName: "ExampleDaemon",
                servicePort: nil
            )
        ]
        XCTAssertFalse(store.add(daemon))
        XCTAssertTrue(store.validationError?.contains("cannot configure privileged") == true)

        var overlap = validPreset(name: "Overlap")
        overlap.helperProcessNames = ["Shared"]
        overlap.protectedProcessNames = ["shared"]
        XCTAssertFalse(store.add(overlap))
        XCTAssertTrue(store.validationError?.contains("Protected process names") == true)
    }

    func testStoredAndIntentPresetsAreRevalidatedBeforeUse() throws {
        let valid = validPreset(name: "Valid")
        var unsafe = validPreset(name: "Unsafe")
        unsafe.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "com.example.unsafe",
                plistPath: "/Library/LaunchDaemons/com.example.unsafe.plist",
                processName: "UnsafeDaemon",
                servicePort: nil
            )
        ]
        let original = try JSONEncoder().encode([valid, unsafe])
        let olderCorruptPayload = Data("older corrupt payload".utf8)
        defaults.set(original, forKey: key)
        defaults.set(olderCorruptPayload, forKey: "\(key).corruptBackup")

        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        let catalog = WatchedPresetCatalog(suiteName: suiteName, key: key)

        XCTAssertEqual(store.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(catalog.entities().map(\.displayName), ["Valid"])
        XCTAssertTrue(store.persistenceIssue?.contains("Rejected 1") == true)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.data(forKey: key), original)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), olderCorruptPayload)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        XCTAssertTrue(store.persistenceIssue?.contains("\(key).rejectedMigrationBackup") == true)
        XCTAssertTrue(store.canExportPresets)

        XCTAssertFalse(store.add(validPreset(name: "New")))
        XCTAssertFalse(store.remove(valid))
        XCTAssertEqual(store.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(defaults.data(forKey: key), original)

        store.resetAfterCorruption()

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), olderCorruptPayload)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        let committed = try JSONDecoder().decode(
            [WatchedAppPreset].self,
            from: XCTUnwrap(defaults.data(forKey: key))
        )
        XCTAssertEqual(committed.map(\.displayName), ["Valid"])
    }

    func testBuiltInGlobalProtectLifecycleIdentityIsImmutable() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var modified = WatchedAppPreset.globalProtect
        modified.systemLaunchDaemonJobs[0].plistPath = "/Library/LaunchDaemons/other.plist"

        XCTAssertFalse(store.update(modified))
        XCTAssertEqual(store.presets, [.globalProtect])
        XCTAssertTrue(store.validationError?.contains("cannot be modified") == true)
    }

    private func validPreset(name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: "\(name.trimmingCharacters(in: .whitespaces))Process",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name.trimmingCharacters(in: .whitespaces)).app"
        )
    }
}
