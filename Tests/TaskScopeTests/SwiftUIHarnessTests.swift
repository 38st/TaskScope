import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class SwiftUIHarnessTests: XCTestCase {
    func testLifecycleDryRunListsConfiguredTargetsWithoutPerformingActions() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: ["ExampleDaemon"],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(
                    label: "example.agent",
                    plistPath: "/Library/LaunchAgents/example.agent.plist"
                )
            ]
        )

        let operations = SettingsView.lifecycleDryRunOperations(for: preset)

        XCTAssertTrue(operations.contains { $0.contains("/Applications/Example.app") })
        XCTAssertTrue(operations.contains { $0.contains("example.agent") })
        XCTAssertTrue(operations.contains { $0.contains("ExampleHelper") })
        XCTAssertTrue(operations.contains { $0.contains("Never signal") && $0.contains("ExampleDaemon") })

        let globalProtectOperations = SettingsView.lifecycleDryRunOperations(for: .globalProtect)
        XCTAssertTrue(globalProtectOperations.contains { $0.contains("Keep Off") })
        XCTAssertTrue(globalProtectOperations.contains { $0.contains("do not disable") })
    }

    func testQuickPresetPrefersTrustedExecutablePathOverReportedCommand() {
        var process = process(pid: 70, parentPID: 1, name: "Example")
        process.command = "/Applications/Forged.app/Contents/MacOS/Forged"
        process.executablePath = "/Applications/Real.app/Contents/MacOS/Real"

        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Example"),
            "/Applications/Real.app"
        )
        process.executablePath = nil
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Example"),
            "/Applications/Forged.app"
        )
    }
    func testProcessRowScopesAccessibilitySummaryAndPreservesActions() throws {
        let target = process(
            pid: 70,
            parentPID: 1,
            name: "Accessible",
            cpu: 42.5,
            memoryMB: 2_048
        )
        let row = ProcessRow(
            process: target,
            isCurrentProcess: false,
            isSelected: false,
            isKeyboardSelected: false,
            isHighlightedCPU: true,
            isHighlightedMEM: true,
            showsExpandedMetrics: true,
            stopAction: {},
            toggleSelection: {},
            detailAction: {},
            forceStopAction: {},
            copyCommandAction: {}
        )
        let inspected = try row.inspect()
        let stack = try inspected.find(ViewType.HStack.self)

        XCTAssertThrowsError(
            try stack.accessibilityValue(),
            "The row container must not propagate its summary to every child element"
        )

        let identity = try stack.find(ViewType.VStack.self)
        XCTAssertEqual(try identity.accessibilityLabel().string(), "Accessible, PID 70")
        XCTAssertEqual(
            try identity.accessibilityValue().string(),
            "CPU 42.5 percent, memory 2,048 megabytes, high CPU, high memory"
        )
        XCTAssertEqual(
            try identity.accessibilityHint().string(),
            "Command: /Applications/Accessible.app/Contents/MacOS/Accessible"
        )

        let buttons = stack.findAll(ViewType.Button.self)
        XCTAssertEqual(try buttons[0].accessibilityLabel().string(), "Add Accessible to selection")
        XCTAssertEqual(try buttons[1].accessibilityLabel().string(), "Stop Accessible")
    }

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
        XCTAssertEqual(confirmation.pendingTermination?.process.identity, needle.identity)
        XCTAssertEqual(confirmation.pendingTermination?.mode, .normal)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        let presented = try view.inspect()
        XCTAssertNoThrow(try presented.find(text: "Stop Process?"))
        XCTAssertNoThrow(try presented.find(text: "Stop Needle"))
        XCTAssertThrowsError(
            try presented.find(button: "Force Stop Needle"),
            "A normal Stop confirmation must not expose SIGKILL"
        )
        XCTAssertNoThrow(
            try presented.find(
                text: "Send a normal quit signal to PID 71, allowing the process to clean up before it exits."
            )
        )

        try presented.find(button: "Cancel").tap()
        XCTAssertNil(confirmation.pendingTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testForceStopUsesDistinctConfirmationWithoutNormalStopAction() async throws {
        let target = process(pid: 72, parentPID: 1, name: "ForceTarget")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        confirmation.requestTermination(target, mode: .force)

        let presented = try makePopover(
            fixture: fixture,
            confirmationState: confirmation
        ).inspect()

        XCTAssertEqual(confirmation.pendingTermination?.process.identity, target.identity)
        XCTAssertEqual(confirmation.pendingTermination?.mode, .force)
        XCTAssertNoThrow(try presented.find(text: "Force Stop Process?"))
        XCTAssertNoThrow(try presented.find(button: "Force Stop ForceTarget"))
        XCTAssertThrowsError(try presented.find(button: "Stop ForceTarget"))
        XCTAssertNoThrow(
            try presented.find(
                text: "Immediately send a kill signal to PID 72. The process cannot clean up before it exits."
            )
        )
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

        XCTAssertEqual(
            confirmation.pendingBatchTermination?.targets,
            [first.identity, second.identity]
        )
        XCTAssertEqual(confirmation.pendingBatchTermination?.mode, .normal)
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
        XCTAssertThrowsError(try presented.find(button: "Force Stop Selected"))
        XCTAssertNoThrow(try presented.find(text: confirmation.batchMessage))

        try presented.find(button: "Cancel").tap()
        XCTAssertNil(confirmation.pendingBatchTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        confirmation.requestBatch([first.identity, second.identity], mode: .force)
        let forcePresented = try makePopover(
            fixture: fixture,
            confirmationState: confirmation
        ).inspect()
        XCTAssertEqual(confirmation.pendingBatchTermination?.mode, .force)
        XCTAssertNoThrow(try forcePresented.find(text: "Force Stop Selected Processes?"))
        XCTAssertNoThrow(try forcePresented.find(button: "Force Stop Selected"))
        XCTAssertThrowsError(try forcePresented.find(button: "Stop Selected"))
        XCTAssertEqual(
            confirmation.batchMessage,
            "Force stop 2 selected processes: First, Second."
        )
    }

    func testPresetCardDestructiveActionRequiresVisibleConfirmation() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        let card = try view.inspect().find(PresetCard.self)

        XCTAssertNoThrow(try card.find(text: "Keep GlobalProtect Off"))
        XCTAssertNoThrow(
            try card.find(
                text: "Persistently disables its user launch agents. Open turns them back on."
            )
        )

        try card.find(button: "Quit All Killable").tap()

        XCTAssertEqual(confirmation.pendingPresetAction?.action, .quitAll)
        XCTAssertEqual(
            confirmation.pendingPresetAction?.preset.id,
            WatchedAppPreset.globalProtectID
        )
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
        let presented = try view.inspect()
        XCTAssertNoThrow(try presented.find(text: "Quit All Killable"))
        XCTAssertNoThrow(
            try presented.find(
                text: "TaskScope will unload the user launch agents (com.paloaltonetworks.gp.pangpa, com.paloaltonetworks.gp.pangps). It will then stop the currently running matches for: GlobalProtect, PanGPA. A process still running 3 seconds after the stop request is force stopped."
            )
        )

        try presented.find(button: "Cancel").tap()
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    /// The Open button must address the preset it belongs to by identity. A
    /// display-name lookup also matches other presets' main process names, so a
    /// cross-field collision used to open a different preset than the one clicked.
    func testPresetCardOpenSubmitsTheClickedPresetIdentityNotItsDisplayName() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.watchedApps
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        let alpha = WatchedAppPreset(
            displayName: "Alpha",
            mainProcessName: "Beta",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Alpha.app"
        )
        let beta = WatchedAppPreset(
            displayName: "Beta",
            mainProcessName: "Gamma",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Beta.app"
        )
        XCTAssertTrue(store.add(alpha))
        XCTAssertTrue(store.add(beta))
        XCTAssertEqual(
            store.presets.first { $0.matchesLookupName("Beta") }?.id,
            alpha.id,
            "precondition: a name lookup for Beta resolves to Alpha"
        )
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { store.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)

        let recorder = CommandRecorder()
        AppCommandBus.shared.install { command in
            recorder.record(command)
            return TaskScopeCommandResult(status: .completed, message: "recorded")
        }
        defer {
            AppCommandBus.shared.install { _ in
                TaskScopeCommandResult(status: .rejected, message: "No handler installed by this test.")
            }
        }

        let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState())
        let cards = try view.inspect().findAll(PresetCard.self)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(try cards[1].actualView().snapshot.preset.id, beta.id)

        try cards[1].find(button: "Open").tap()
        await settle()

        XCTAssertEqual(
            recorder.commands,
            [.openPresetEntity(WatchedPresetCommandTarget(id: beta.id, displayName: "Beta"))]
        )
    }

    /// A row can be on screen purely because the search filter surfaced it, even
    /// though it ranks below the display limit. The preset draft must be built from
    /// the full inventory (`selectedProcessesSnapshot()`), not from the limited,
    /// unfiltered display slice — the two sets are not nested.
    func testSaveSelectionAsPresetDraftKeepsSearchSurfacedSelection() async throws {
        let hotA = process(pid: 91, parentPID: 1, name: "HotA", cpu: 90)
        let hotB = process(pid: 92, parentPID: 1, name: "HotB", cpu: 80)
        let needle = process(pid: 93, parentPID: 1, name: "Needle", cpu: 1)
        let fixture = await makeFixture(processes: [hotA, hotB, needle])
        defer { fixture.stores.cleanup() }

        // Production wires this provider from settings.processListLimit and
        // republishes via applyCurrentDisplayLimit(). A limit of 2 keeps the fixture
        // small; all that matters is that the inventory exceeds it.
        fixture.manager.processListLimitProvider = { 2 }
        fixture.manager.applyCurrentDisplayLimit()
        fixture.stores.settings.searchText = "Needle"

        // Filtering runs before the limit, so the search surfaces a row that the
        // unfiltered display slice drops.
        XCTAssertEqual(fixture.manager.processes.map(\.pid), [hotA.pid, hotB.pid])

        let view = makePopover(
            fixture: fixture,
            confirmationState: ProcessConfirmationState()
        )
        let rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].actualView().process.identity, needle.identity)

        try rows[0].findAll(ViewType.Button.self)[0].tap()
        XCTAssertEqual(fixture.manager.selectedPids, [needle.pid])

        // What `selectedProcessesForPreset()` now calls. ViewInspector 0.10.3 has no
        // `.contextMenu` support, so the accessor is exercised against the same
        // ProcessManager instance the view holds.
        let draftProcesses = fixture.manager.selectedProcessesSnapshot()
        XCTAssertEqual(draftProcesses.map(\.pid), [needle.pid])

        // The collection this used to read from would have dropped it entirely.
        let displaySliceOnly = fixture.manager.processes.filter {
            fixture.manager.selectedPids.contains($0.pid)
        }
        XCTAssertTrue(
            displaySliceOnly.isEmpty,
            "guards the regression: the display slice does not contain the selected row"
        )

        let sheet = QuickWatchedPresetSheet(
            draft: QuickWatchedPresetDraft(processes: draftProcesses),
            onSave: { _ in nil },
            onCancel: {}
        )
        XCTAssertNoThrow(
            try sheet.inspect().find(text: "Needle"),
            "Preset sheet should summarise the selected process, not report it as empty"
        )
    }

    /// A saved entry without a kernel executable path can only match by name.
    /// The recall preview must say so next to every such entry.
    func testRecallSheetMarksLegacyNameMatches() throws {
        let matched = process(pid: 20, parentPID: 1, name: "Example")
        let legacyMatched = SavedSelectionsStore.SavedProcess(
            pid: 10,
            command: "Example",
            executableName: "Example"
        )
        let legacyMissing = SavedSelectionsStore.SavedProcess(
            pid: 11,
            command: "Other",
            executableName: "Other"
        )
        let pathBound = SavedSelectionsStore.SavedProcess(
            pid: 12,
            command: "/Applications/Bound.app/Contents/MacOS/Bound",
            executableName: "Bound",
            executablePath: "/Applications/Bound.app/Contents/MacOS/Bound"
        )
        let selection = SavedSelectionsStore.SavedSelection(
            name: "Mixed",
            pids: [10, 11, 12],
            processes: [legacyMatched, legacyMissing, pathBound]
        )
        let result = SavedSelectionsStore.RecallResult(
            matched: [matched],
            unmatched: [legacyMissing, pathBound],
            ambiguous: [],
            legacyUnsupported: false,
            legacyNameMatches: [matched.identity]
        )
        let sheet = SavedSelectionRecallSheet(
            selection: selection,
            result: result,
            onApply: {},
            onCancel: {}
        )

        let inspected = try sheet.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Example — PID 20 · legacy name match"))
        XCTAssertNoThrow(try inspected.find(text: "Other · legacy name match"))
        XCTAssertNoThrow(try inspected.find(text: "Bound"))
        XCTAssertThrowsError(try inspected.find(text: "Bound · legacy name match"))
    }

    func testQuickPresetSheetKeepsRejectedDraftAndShowsStoreError() throws {
        let target = process(pid: 94, parentPID: 1, name: "Rejected")
        var saveAttempts = 0
        let form = QuickWatchedPresetFormState(
            displayName: target.name,
            mainProcessName: target.name,
            helperNames: "",
            appPath: "/Applications/Rejected.app"
        )
        let sheet = QuickWatchedPresetSheet(
            draft: QuickWatchedPresetDraft(processes: [target]),
            onSave: { _ in
                saveAttempts += 1
                return "A watched preset with that display name already exists."
            },
            onCancel: {},
            form: form
        )

        let inspected = try sheet.inspect()
        try inspected.find(button: "Add Preset").tap()

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(
            form.validationError,
            "A watched preset with that display name already exists."
        )
        XCTAssertNoThrow(
            try sheet.inspect().find(
                text: "A watched preset with that display name already exists."
            )
        )
        XCTAssertNoThrow(try sheet.inspect().find(button: "Add Preset"))
    }

    func testQuickAutoStopSheetKeepsRejectedDraftAndShowsStoreError() throws {
        let target = process(pid: 96, parentPID: 1, name: "Rejected")
        var saveAttempts = 0
        let form = QuickAutoStopRuleFormState(
            processName: target.name,
            runtimeMinutes: 5,
            action: .prompt
        )
        let sheet = QuickAutoStopRuleSheet(
            process: target,
            existingRule: nil,
            onSave: { _, _, _ in
                saveAttempts += 1
                return "Auto-stop rule data is in recovery mode."
            },
            onCancel: {},
            form: form
        )

        try sheet.inspect().find(button: "Add Rule").tap()

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(form.validationError, "Auto-stop rule data is in recovery mode.")
        XCTAssertNoThrow(
            try sheet.inspect().find(text: "Auto-stop rule data is in recovery mode.")
        )
        XCTAssertNoThrow(try sheet.inspect().find(button: "Add Rule"))
    }

    func testCurrentProcessSelectionControlIsDisabledAndExplainsProtection() throws {
        let target = process(pid: 95, parentPID: 1, name: "TaskScope")
        var selectionAttempts = 0
        let row = ProcessRow(
            process: target,
            isCurrentProcess: true,
            isSelected: false,
            isKeyboardSelected: false,
            isHighlightedCPU: false,
            isHighlightedMEM: false,
            stopAction: {},
            toggleSelection: { selectionAttempts += 1 },
            detailAction: {},
            forceStopAction: {},
            copyCommandAction: {}
        )

        let selectionButton = try row.inspect().findAll(ViewType.Button.self)[0]
        XCTAssertTrue(selectionButton.isDisabled())
        XCTAssertEqual(
            try selectionButton.accessibilityLabel().string(),
            "TaskScope cannot be selected"
        )
        XCTAssertEqual(
            try selectionButton.accessibilityHint().string(),
            "TaskScope protects its own process"
        )
        XCTAssertEqual(selectionAttempts, 0)
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

        // The disclosure overlays the row's selection and Stop buttons.
        let disclosureButton = try view.inspect().findAll(ViewType.Button.self)[2]
        try disclosureButton.tap()
        XCTAssertEqual(disclosure.expandedPIDs, [parent.pid])

        rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(
            try rows.map { try $0.actualView().process.pid },
            [parent.pid, child.pid]
        )

        try view.inspect().findAll(ViewType.Button.self)[2].tap()
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
            "Built-in",
            "Built-in lifecycle: 1 protected system daemon",
            SettingsView.builtInDaemonGuidance,
            "Global Hotkey"
        ] {
            XCTAssertNoThrow(
                try inspected.find(text: expectedText),
                "Missing Settings UI content: \(expectedText)"
            )
        }
        XCTAssertThrowsError(
            try inspected.find(button: "Edit"),
            "The built-in GlobalProtect identity must not expose an editor."
        )
    }

    func testSettingsRecoveryUIRequiresExplicitReset() throws {
        let suiteName = "TaskScope.SettingsRecoveryUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = Data([0xFF, 0x04])
        defaults.set(corrupt, forKey: "settings")

        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let view = SettingsView(
            settings: settings,
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults,
                key: "rules",
                eventsKey: "events",
                inventory: UIInventory(processes: [])
            )
        )
        let inspected = try view.inspect()

        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        XCTAssertNoThrow(try inspected.find(text: "Recovered Settings"))
        try inspected.find(button: "Reset Settings After Backup").tap()

        XCTAssertFalse(settings.isReadOnlyAfterCorruption)
        XCTAssertNil(settings.recoveryMessage)
        XCTAssertNotEqual(defaults.data(forKey: "settings"), corrupt)
    }

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
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
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "00:10",
            startTime: "Sun Jul 26 12:00:00 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
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
private final class CommandRecorder {
    private(set) var commands: [TaskScopeCommand] = []

    func record(_ command: TaskScopeCommand) {
        commands.append(command)
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
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
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
