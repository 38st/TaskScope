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
        store.presets = []
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
        store.presets = []
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
