import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class SwiftUIHarnessTests: XCTestCase {
    func testFilteredProcessViewRendersAndSelectsOnlyMatchingRow() async throws {
        let needle = process(pid: 71, parentPID: 1, name: "Needle", cpu: 42)
        let hidden = process(pid: 72, parentPID: 1, name: "Hidden", cpu: 3)
        let fixture = await makeFixture(processes: [needle, hidden])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.searchText = "Needle"

        let confirmation = ProcessConfirmationState()
        let view = makePopover(
            fixture: fixture,
            confirmationState: confirmation
        )
        let rows = try view.inspect().findAll(ProcessRow.self)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].actualView().process.identity, needle.identity)

        let rowButtons = rows[0].findAll(ViewType.Button.self)
        XCTAssertEqual(rowButtons.count, 2)

        try rowButtons[0].tap()
        XCTAssertEqual(fixture.manager.selectedPids, [needle.pid])
        XCTAssertFalse(fixture.manager.selectedPids.contains(hidden.pid))

        try rowButtons[1].tap()
        XCTAssertEqual(confirmation.pendingTermination?.identity, needle.identity)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        let presented = try view.inspect()
        XCTAssertNoThrow(try presented.find(text: "Stop Process?"))
        XCTAssertNoThrow(try presented.find(text: "Stop Needle"))
        XCTAssertNoThrow(try presented.find(text: "Force Stop Needle"))
        XCTAssertNoThrow(
            try presented.find(
                text: "Send a normal quit signal to PID 71. Force Stop sends an immediate kill signal if the process does not respond."
            )
        )

        try presented.find(button: "Cancel").tap()
        XCTAssertNil(confirmation.pendingTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testBatchConfirmationUsesImmutableTargetSnapshotAndExposesActions() async throws {
        let first = process(pid: 73, parentPID: 1, name: "First")
        let second = process(pid: 74, parentPID: 1, name: "Second")
        let fixture = await makeFixture(processes: [first, second])
        defer { fixture.stores.cleanup() }

        let confirmation = ProcessConfirmationState()
        var requestedTargets = [first.identity, second.identity]
        confirmation.requestBatch(requestedTargets)
        requestedTargets.removeAll()

        XCTAssertEqual(confirmation.batchTargets, [first.identity, second.identity])
        XCTAssertEqual(
            confirmation.batchMessage,
            "Stop 2 selected processes: First, Second."
        )

        let view = makePopover(
            fixture: fixture,
            confirmationState: confirmation
        )
        let presented = try view.inspect()

        XCTAssertNoThrow(try presented.find(text: "Stop Selected Processes?"))
        XCTAssertNoThrow(try presented.find(text: "Stop Selected"))
        XCTAssertNoThrow(try presented.find(text: "Force Stop Selected"))
        XCTAssertNoThrow(try presented.find(text: confirmation.batchMessage))

        try presented.find(button: "Cancel").tap()
        XCTAssertFalse(confirmation.isBatchPresented)
        XCTAssertTrue(confirmation.batchTargets.isEmpty)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testTreeDisclosureControlsRenderedChildVisibility() async throws {
        let parent = process(pid: 81, parentPID: 1, name: "Parent")
        let child = process(pid: 82, parentPID: parent.pid, name: "Child")
        let fixture = await makeFixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        let root = ProcessTreeNode(
            process: parent,
            children: [ProcessTreeNode(process: child, children: [])]
        )
        let disclosure = TreeDisclosureModel()
        let view = TreeVisibilityHarness(
            root: root,
            manager: fixture.manager,
            settings: fixture.stores.settings,
            disclosure: disclosure
        )

        var rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(try rows.map { try $0.actualView().process.pid }, [parent.pid])

        let disclosureButton = try view.inspect().findAll(ViewType.Button.self)[0]
        try disclosureButton.tap()
        XCTAssertEqual(disclosure.expandedPIDs, [parent.pid])

        rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(
            try rows.map { try $0.actualView().process.pid },
            [parent.pid, child.pid]
        )

        try view.inspect().findAll(ViewType.Button.self)[0].tap()
        XCTAssertTrue(disclosure.expandedPIDs.isEmpty)
        XCTAssertEqual(try view.inspect().findAll(ProcessRow.self).count, 1)
    }

    func testSettingsViewHasFixedLayoutAndPrimaryTabContent() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let view = SettingsView(
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules
        )
        let inspected = try view.inspect()
        let tabView = try inspected.find(ViewType.TabView.self)
        let frame = try tabView.fixedFrame()

        XCTAssertEqual(frame.width, 520)
        XCTAssertEqual(frame.height, 540)
        XCTAssertEqual(NotificationService.shared.authorizationState, .unknown)

        for expectedText in [
            "General",
            "Watched Apps",
            "Auto-Stop",
            "Hotkey",
            "Auto-refresh process list",
            "Notify on watched process changes",
            "GlobalProtect",
            "Add",
            "Export",
            "Import",
            "Global Hotkey"
        ] {
            XCTAssertNoThrow(
                try inspected.find(text: expectedText),
                "Missing Settings UI content: \(expectedText)"
            )
        }
    }

    private func process(
        pid: Int32,
        parentPID: Int32,
        name: String,
        cpu: Double = 1,
        memoryMB: Double = 128
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: parentPID,
            cpu: cpu,
            memoryMB: memoryMB,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "00:10",
            startTime: "Sun Jul 26 12:00:00 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }

    private func makeFixture(processes: [AppProcess]) async -> UIFixture {
        let inventory = UIInventory(processes: processes)
        let signaler = UIRecordingSignaler()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: signaler,
            lifecycle: UILifecycle()
        )
        manager.enableNotifications = false

        let stores = makeStores(inventory: inventory)
        await manager.loadProcessList(showMessage: false)

        return UIFixture(
            manager: manager,
            signaler: signaler,
            stores: stores
        )
    }

    private func makePopover(
        fixture: UIFixture,
        confirmationState: ProcessConfirmationState
    ) -> TaskScopePopoverView {
        TaskScopePopoverView(
            processManager: fixture.manager,
            loginItemManager: LoginItemManager(service: UILoginItemService()),
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            savedSelections: fixture.stores.savedSelections,
            autoStopRules: fixture.stores.autoStopRules,
            history: fixture.stores.history,
            presentationStyle: .menuBarCompact,
            openFullWindow: nil,
            confirmationState: confirmationState,
            activityMonitor: UIActivityMonitor()
        )
    }

    private func makeStores(inventory: UIInventory) -> UIStores {
        let suiteName = "TaskScope.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UIStores(
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
private struct TreeVisibilityHarness: View {
    let root: ProcessTreeNode
    let manager: ProcessManager
    let settings: SettingsStore
    @ObservedObject var disclosure: TreeDisclosureModel

    @State private var keyboardSelectedPID: Int32?
    @State private var pendingTermination: AppProcess?
    @State private var detailProcess: AppProcess?
    @State private var detailData: ProcessDetail?
    @State private var detailFailed = false

    var body: some View {
        ProcessTreeRow(
            node: root,
            depth: 0,
            settings: settings,
            processManager: manager,
            keyboardSelectedPid: $keyboardSelectedPID,
            pendingTermination: $pendingTermination,
            detailProcess: $detailProcess,
            detailData: $detailData,
            detailFailed: $detailFailed,
            expandedPids: Binding(
                get: { disclosure.expandedPIDs },
                set: { disclosure.expandedPIDs = $0 }
            ),
            showsExpandedMetrics: false,
            openInActivityMonitor: { _ in },
            contextMenuContent: { _ in EmptyView() }
        )
    }
}

@MainActor
private final class TreeDisclosureModel: ObservableObject {
    @Published var expandedPIDs: Set<Int32> = []
}

private struct UIInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class UIRecordingSignaler: ProcessSignaling {
    struct Signal: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private(set) var sent: [Signal] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(Signal(signal: signal, pid: pid))
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        false
    }
}

private struct UILifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async {}
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}

private struct UILoginItemService: LoginItemServicing {
    var state: LoginItemState = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
private struct UIActivityMonitor: ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome {
        .missingProcess
    }
}

@MainActor
private struct UIFixture {
    var manager: ProcessManager
    var signaler: UIRecordingSignaler
    var stores: UIStores
}

@MainActor
private struct UIStores {
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
