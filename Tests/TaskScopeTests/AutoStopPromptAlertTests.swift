import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Drives the real `.alert(_:isPresented:presenting:)` modifier in
/// `TaskScopePopoverView` through ViewInspector.
///
/// ViewInspector's `ViewType.Button.tap()` only invokes the button's action closure; it does
/// not perform SwiftUI's automatic `isPresented = false` write-back. That write-back is driven
/// explicitly here with `InspectableView<ViewType.Alert>.dismiss()`, which for the iOS 15-style
/// alert sets `binding.wrappedValue = false` and therefore runs the app's own binding setter.
/// Both the button action and the binding setter are the production closures.
@MainActor
final class AutoStopPromptAlertTests: XCTestCase {
    /// Sub-claim (a): one prompt queued, user taps "Stop Now".
    func testStopNowOnTheOnlyPromptActuallyStopsThatProcess() async throws {
        let target = process(pid: 41, name: "Example")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41], "setup: one prompt queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example has run for 03:00, beyond the 1-minute rule. Stop it now?"),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Stop Now").tap()
        try alert.dismiss()
        await settle()

        XCTAssertEqual(
            stopped.pids,
            [41],
            "Tapping Stop Now must send a stop request for the process the alert displayed"
        )
        XCTAssertEqual(
            store.events.first?.outcome,
            .stopped,
            "The logged outcome for a Stop Now tap must be .stopped, not .dismissed"
        )
    }

    /// Sub-claim (b): two prompts queued, user taps "Stop Now" on prompt #1.
    func testStopNowNeverStopsAProcessTheAlertDidNotDisplay() async throws {
        let shown = process(pid: 41, name: "Example")
        let unshown = process(pid: 42, name: "Other")
        let fixture = await makeFixture(processes: [shown, unshown])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42], "setup: two prompts queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example has run for 03:00, beyond the 1-minute rule. Stop it now?"),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Stop Now").tap()
        try alert.dismiss()
        await settle()

        XCTAssertFalse(
            stopped.pids.contains(42),
            "Stop Now on the pid 41 prompt must never stop pid 42, which the alert never displayed"
        )
        XCTAssertEqual(stopped.pids, [41], "Stop Now must stop the displayed process, pid 41")
    }

    /// Sub-claim (c): two prompts queued, user taps "Dismiss".
    func testDismissConsumesOnlyThePromptTheAlertDisplayed() async throws {
        let shown = process(pid: 41, name: "Example")
        let queued = process(pid: 42, name: "Other")
        let fixture = await makeFixture(processes: [shown, queued])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42], "setup: two prompts queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example has run for 03:00, beyond the 1-minute rule. Stop it now?"),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Dismiss").tap()
        try alert.dismiss()
        await settle()

        XCTAssertEqual(
            store.pendingPrompts.map(\.process.pid),
            [42],
            "One Dismiss tap must consume only the displayed prompt; pid 42 must still be queued"
        )
        XCTAssertEqual(
            store.events.count,
            1,
            "One Dismiss tap must log exactly one event, not silently dismiss the unseen prompt too"
        )
    }

    // MARK: - Helpers

    /// Lets the `Task { await autoStopRules.stopCurrentPrompt() }` enqueued by the button
    /// action run on the MainActor, mirroring SwiftUI's deferred execution of that Task.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func process(pid: Int32, name: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 1,
            memoryMB: 128,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "03:00",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }

    private func makeFixture(processes: [AppProcess]) async -> PromptFixture {
        let inventory = PromptInventory(processes: processes)
        let signaler = PromptSignaler()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: signaler,
            lifecycle: PromptLifecycle()
        )
        manager.enableNotifications = false

        let stores = makeStores(inventory: inventory)
        await manager.loadProcessList(showMessage: false)

        return PromptFixture(manager: manager, signaler: signaler, stores: stores)
    }

    private func makePopover(fixture: PromptFixture) -> TaskScopePopoverView {
        TaskScopePopoverView(
            processManager: fixture.manager,
            loginItemManager: LoginItemManager(service: PromptLoginItemService()),
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            savedSelections: fixture.stores.savedSelections,
            autoStopRules: fixture.stores.autoStopRules,
            history: fixture.stores.history,
            presentationStyle: .menuBarCompact,
            openFullWindow: nil,
            confirmationState: ProcessConfirmationState(),
            activityMonitor: PromptActivityMonitor()
        )
    }

    private func makeStores(inventory: PromptInventory) -> PromptStores {
        let suiteName = "TaskScope.AutoStopPromptAlertTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PromptStores(
            suiteName: suiteName,
            defaults: defaults,
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "selections"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults,
                key: "rules",
                eventsKey: "events",
                inventory: inventory
            ),
            history: ProcessHistory(inventory: inventory)
        )
    }
}

@MainActor
private final class StopRecorder {
    private(set) var pids: [Int32] = []

    func record(_ pid: Int32) -> ProcessActionResult {
        pids.append(pid)
        return .stopped
    }
}

private struct PromptInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class PromptSignaler: ProcessSignaling {
    private(set) var sent: [Int32] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(pid)
        return true
    }

    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct PromptLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}

private struct PromptLoginItemService: LoginItemServicing {
    var state: LoginItemState = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
private struct PromptActivityMonitor: ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome {
        .missingProcess
    }
}

@MainActor
private struct PromptFixture {
    var manager: ProcessManager
    var signaler: PromptSignaler
    var stores: PromptStores
}

@MainActor
private struct PromptStores {
    var suiteName: String
    var defaults: UserDefaults
    var settings: SettingsStore
    var watchedApps: WatchedAppsStore
    var savedSelections: SavedSelectionsStore
    var autoStopRules: AutoStopRulesStore
    var history: ProcessHistory

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
