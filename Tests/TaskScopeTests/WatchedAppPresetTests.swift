import XCTest
@testable import TaskScope

final class WatchedAppPresetTests: XCTestCase {
    func testDecodingOlderPresetDefaultsNewFields() throws {
        let json = """
        {
          "displayName": "Example",
          "mainProcessName": "ExampleApp",
          "appPath": "/Applications/Example.app"
        }
        """.data(using: .utf8)!

        let preset = try JSONDecoder().decode(WatchedAppPreset.self, from: json)

        XCTAssertEqual(preset.displayName, "Example")
        XCTAssertEqual(preset.mainProcessName, "ExampleApp")
        XCTAssertEqual(preset.helperProcessNames, [])
        XCTAssertEqual(preset.protectedProcessNames, [])
        XCTAssertEqual(preset.userLaunchAgentJobs, [])
        XCTAssertEqual(preset.systemLaunchDaemonJobs, [])
        XCTAssertTrue(preset.notificationsEnabled)
        XCTAssertEqual(preset.priority, 0)
    }

    func testMatchesLookupNameTrimsAndIgnoresCase() {
        let preset = WatchedAppPreset(
            displayName: "GlobalProtect",
            mainProcessName: "PanGPA",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/GlobalProtect.app"
        )

        XCTAssertTrue(preset.matchesLookupName(" globalprotect "))
        XCTAssertTrue(preset.matchesLookupName("pangpa"))
        XCTAssertFalse(preset.matchesLookupName(" "))
        XCTAssertFalse(preset.matchesLookupName("PanGPS"))
    }

    func testSnapshotAggregateStatusPrioritizesMainAppOverHelpers() {
        let preset = WatchedAppPreset.globalProtect

        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: ["PanGPA"])].aggregateStatus,
            .helpersOnly
        )
        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: ["GlobalProtect", "PanGPA"])].aggregateStatus,
            .watchedRunning
        )
        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: [])].aggregateStatus,
            .idle
        )
    }
}
