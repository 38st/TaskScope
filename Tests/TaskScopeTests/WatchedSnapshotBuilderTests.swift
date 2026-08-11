import XCTest
@testable import TaskScope

final class WatchedSnapshotBuilderTests: XCTestCase {
    func testMainAndHelperMatchesAreScopedToConfiguredBundle() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        let inventory = [
            process(pid: 10, name: "Example", path: "/Applications/Forged.app/Contents/MacOS/Example"),
            process(pid: 11, name: "Example Helper", path: "/Applications/Example.app/Contents/Helpers/Example Helper"),
            process(pid: 12, name: "Example", path: "/Applications/Example.app/Contents/MacOS/Example")
        ]

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99)
            .snapshot(for: preset, in: inventory)

        XCTAssertEqual(snapshot.runningNames, ["Example", "Example Helper"])
    }

    func testProtectedNameMatchingRemainsOutsideBundleScope() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: ["Example Service"],
            appPath: "/Applications/Example.app"
        )
        let service = process(pid: 20, name: "Example Service", path: "/Library/Example Service")

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99)
            .snapshot(for: preset, in: [service])

        XCTAssertEqual(snapshot.runningNames, ["Example Service"])
    }

    func testExcludedProcessNeverAppearsInSnapshot() {
        let preset = WatchedAppPreset(
            displayName: "TaskScope",
            mainProcessName: "TaskScope",
            helperProcessNames: [],
            protectedProcessNames: ["TaskScope"],
            appPath: "/Applications/TaskScope.app"
        )
        let current = process(
            pid: 42,
            name: "TaskScope",
            path: "/Applications/TaskScope.app/Contents/MacOS/TaskScope"
        )

        let snapshot = WatchedSnapshotBuilder(excludedPID: 42)
            .snapshot(for: preset, in: [current])

        XCTAssertTrue(snapshot.runningNames.isEmpty)
    }

    private func process(pid: Int32, name: String, path: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: path,
            executablePath: path,
            elapsedTime: "00:01",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }
}
