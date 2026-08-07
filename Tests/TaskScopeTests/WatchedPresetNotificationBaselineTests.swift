import XCTest
@testable import TaskScope

/// Adding a watched preset for an app that is *already* running must not announce it
/// as having just started.
///
/// The re-baseline used to be computed from `processManager.snapshots` before the
/// refresh, i.e. from snapshots that predated the new preset list and therefore had
/// no entry for it. The next refresh then diffed the new preset's already-running
/// names against a baseline that never contained them.
@MainActor
final class WatchedPresetNotificationBaselineTests: XCTestCase {
    func testAddingAPresetForAnAlreadyRunningAppDoesNotAnnounceAStart() async {
        let running = [appProcess(pid: 41, name: "Slack")]
        let manager = makeManager(inventory: StubInventory(processes: running))

        var started: [Set<String>] = []
        var primed: [Set<String>] = []
        manager.notifyTransitions = { started.append($0) }
        manager.primeNotificationBaseline = { primed.append($0) }

        // The preset list changes to include an app that is already running, and the
        // manager has no snapshot for it yet.
        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }
        XCTAssertTrue(manager.snapshots.isEmpty, "precondition: no snapshot for the new preset")

        await manager.refreshWatchedStatus(showMessage: false, rebaselineNotifications: true)

        XCTAssertTrue(started.isEmpty, "the re-baseline pass must not emit transitions")
        XCTAssertEqual(
            primed,
            [["Slack"]],
            "the baseline must come from the refreshed snapshots, which include the running app"
        )

        // A subsequent ordinary refresh with nothing changed must stay silent.
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertEqual(started, [["Slack"]], "one diff, against a baseline that already had Slack")
    }

    /// The ordinary path must still report a genuine start.
    func testAGenuineStartIsStillReported() async {
        let inventory = StubInventory(processes: [])
        let manager = makeManager(inventory: inventory)
        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }

        var started: [Set<String>] = []
        manager.notifyTransitions = { started.append($0) }

        await manager.refreshWatchedStatus(showMessage: false, rebaselineNotifications: true)
        inventory.processes = [appProcess(pid: 41, name: "Slack")]
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertEqual(started, [["Slack"]], "a real start must still reach the notifier")
    }

    // MARK: - Helpers

    private func makeManager(inventory: any ProcessInventoryProviding) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: InertSignaler(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = true
        return manager
    }

    private func preset(named name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: name,
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app"
        )
    }

    private func appProcess(pid: Int32, name: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 1,
            memoryMB: 1,
            command: name,
            elapsedTime: "01:00",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }
}

private final class StubInventory: ProcessInventoryProviding, @unchecked Sendable {
    var processes: [AppProcess]

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private struct InertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { false }
}
