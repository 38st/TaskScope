import AppKit
import SwiftUI

enum TaskScopeSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case presets = "Presets"

    var id: String {
        rawValue
    }
}

enum ProcessFilterMode: String, CaseIterable, Identifiable {
    case all
    case watched
    case highlighted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .watched: "Watched"
        case .highlighted: "Hot"
        }
    }
}

enum TaskScopePresentationStyle {
    case menuBarCompact
    case expandedWindow
}

@MainActor
final class ProcessConfirmationState: ObservableObject {
    enum PresetAction: String, Equatable {
        case quitApp = "Quit App"
        case quitHelpers = "Quit Helpers"
        case quitAll = "Quit All Killable"
    }

    struct PendingPresetAction: Equatable {
        var preset: WatchedAppPreset
        var action: PresetAction
    }

    @Published var pendingTermination: AppProcess?
    @Published var isBatchPresented = false
    @Published var pendingPresetAction: PendingPresetAction?
    private(set) var batchTargets: [ProcessIdentity] = []

    func requestTermination(_ process: AppProcess) {
        pendingTermination = process
    }

    func clearTermination() {
        pendingTermination = nil
    }

    func requestBatch(_ targets: [ProcessIdentity]) {
        batchTargets = targets
        isBatchPresented = !targets.isEmpty
    }

    func clearBatch() {
        isBatchPresented = false
        batchTargets = []
    }

    func requestPresetAction(_ action: PresetAction, preset: WatchedAppPreset) {
        pendingPresetAction = PendingPresetAction(preset: preset, action: action)
    }

    func clearPresetAction() {
        pendingPresetAction = nil
    }

    var batchMessage: String {
        let names = batchTargets.prefix(3).map { identity in
            let component = URL(fileURLWithPath: identity.command).lastPathComponent
            return component.isEmpty ? identity.command : component
        }
        let suffix = batchTargets.count > names.count
            ? " and \(batchTargets.count - names.count) more"
            : ""
        return "Stop \(batchTargets.count) selected processes: \(names.joined(separator: ", "))\(suffix)."
    }
}

struct TaskScopePopoverView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var savedSelections: SavedSelectionsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    @ObservedObject var history: ProcessHistory
    var presentationStyle: TaskScopePresentationStyle = .menuBarCompact
    var openFullWindow: (() -> Void)?
    private let activityMonitor: any ActivityMonitorCoordinating
    @StateObject private var confirmationState: ProcessConfirmationState

    @State private var detailProcess: AppProcess?
    @State private var detailData: ProcessDetail?
    @State private var detailFailed: Bool = false
    @State private var keyboardSelectedPid: Int32?
    @State private var filterMode: ProcessFilterMode = .all
    @State private var treeMode: Bool = false
    @State private var expandedTreePids: Set<Int32> = []
    @State private var saveSelectionName: String = ""
    @State private var showSaveSelectionSheet: Bool = false
    @State private var pendingRecallSelection: SavedSelectionsStore.SavedSelection?
    @State private var pendingRecallResult: SavedSelectionsStore.RecallResult?
    @State private var renameSelection: SavedSelectionsStore.SavedSelection?
    @State private var renameSelectionName = ""
    @State private var quickAutoStopProcess: AppProcess?
    @State private var quickPresetDraft: QuickWatchedPresetDraft?
    @State private var registeredExtendedMetrics = false

    @MainActor
    init(
        processManager: ProcessManager,
        loginItemManager: LoginItemManager,
        settings: SettingsStore,
        watchedApps: WatchedAppsStore,
        savedSelections: SavedSelectionsStore,
        autoStopRules: AutoStopRulesStore,
        history: ProcessHistory,
        presentationStyle: TaskScopePresentationStyle = .menuBarCompact,
        openFullWindow: (() -> Void)? = nil,
        confirmationState: ProcessConfirmationState? = nil,
        activityMonitor: (any ActivityMonitorCoordinating)? = nil
    ) {
        self.processManager = processManager
        self.loginItemManager = loginItemManager
        self.settings = settings
        self.watchedApps = watchedApps
        self.savedSelections = savedSelections
        self.autoStopRules = autoStopRules
        self.history = history
        self.presentationStyle = presentationStyle
        self.openFullWindow = openFullWindow
        self.activityMonitor = activityMonitor ?? ActivityMonitorCoordinator()
        _confirmationState = StateObject(
            wrappedValue: confirmationState ?? ProcessConfirmationState()
        )
    }

    private var isExpandedWindow: Bool {
        presentationStyle == .expandedWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker

            Divider()

            Group {
                switch settings.selectedSection {
                case .processes:
                    processList
                case .presets:
                    presetsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear {
            guard isExpandedWindow, !registeredExtendedMetrics else { return }
            registeredExtendedMetrics = true
            Task { await processManager.beginExtendedMetrics() }
        }
        .onDisappear {
            guard registeredExtendedMetrics else { return }
            registeredExtendedMetrics = false
            processManager.endExtendedMetrics()
        }
        .onChange(of: processManager.processes) { _, newProcesses in
            if let pid = keyboardSelectedPid, !newProcesses.contains(where: { $0.pid == pid }) {
                keyboardSelectedPid = nil
            }
            expandFilteredTreeAncestors()
        }
        .onChange(of: settings.searchText) { _, _ in
            expandFilteredTreeAncestors()
        }
        .onChange(of: filterMode) { _, _ in
            expandFilteredTreeAncestors()
        }
        .onChange(of: treeMode) { _, enabled in
            if enabled {
                expandFilteredTreeAncestors()
            }
        }
        .onChange(of: renderedProcessIdentities) { _, _ in
            processManager.restrictSelection(to: renderedSelectionProcesses)
        }
        .confirmationDialog(
            "Stop Process?",
            isPresented: Binding(
                get: { confirmationState.pendingTermination != nil },
                set: { isPresented in
                    if !isPresented {
                        confirmationState.clearTermination()
                    }
                }
            ),
            presenting: confirmationState.pendingTermination
        ) { process in
            Button("Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process) }
                confirmationState.clearTermination()
            }

            Button("Force Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process, forceKill: true) }
                confirmationState.clearTermination()
            }

            Button("Cancel", role: .cancel) {
                confirmationState.clearTermination()
            }
        } message: { process in
            Text("Send a normal quit signal to PID \(process.pid). Force Stop sends an immediate kill signal if the process does not respond.")
        }
        .confirmationDialog(
            "Stop Selected Processes?",
            isPresented: $confirmationState.isBatchPresented
        ) {
            Button("Stop Selected", role: .destructive) {
                let targets = confirmationState.batchTargets
                Task { await processManager.batchTerminate(targets) }
                confirmationState.clearBatch()
            }
            Button("Force Stop Selected", role: .destructive) {
                let targets = confirmationState.batchTargets
                Task { await processManager.batchTerminate(targets, forceKill: true) }
                confirmationState.clearBatch()
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearBatch()
            }
        } message: {
            Text(confirmationState.batchMessage)
        }
        .confirmationDialog(
            confirmationState.pendingPresetAction?.action.rawValue ?? "Confirm Preset Action",
            isPresented: Binding(
                get: { confirmationState.pendingPresetAction != nil },
                set: { isPresented in
                    if !isPresented {
                        confirmationState.clearPresetAction()
                    }
                }
            ),
            presenting: confirmationState.pendingPresetAction
        ) { pending in
            Button(pending.action.rawValue, role: .destructive) {
                let preset = pending.preset
                let action = pending.action
                confirmationState.clearPresetAction()
                Task {
                    switch action {
                    case .quitApp:
                        _ = await processManager.quitMainApp(preset)
                    case .quitHelpers:
                        _ = await processManager.quitHelpers(preset)
                    case .quitAll:
                        _ = await processManager.quitAllKillable(preset)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearPresetAction()
            }
        } message: { pending in
            Text(presetConfirmationMessage(for: pending))
        }
        .sheet(item: $detailProcess) { process in
            ProcessDetailSheet(
                process: process,
                detail: detailData,
                failed: detailFailed,
                onClose: {
                    detailProcess = nil
                    detailData = nil
                    detailFailed = false
                }
            )
            .task(id: process.pid) {
                detailData = nil
                detailFailed = false
                if let result = await processManager.detail(for: process) {
                    detailData = result
                } else {
                    detailFailed = true
                }
            }
        }
        .sheet(isPresented: $showSaveSelectionSheet) {
            SaveSelectionSheet(
                name: $saveSelectionName,
                count: processManager.selectedPids.count,
                validationError: savedSelections.validationError,
                onSave: {
                    if savedSelections.save(
                        name: saveSelectionName,
                        processes: processManager.selectedProcessesSnapshot()
                    ) {
                        showSaveSelectionSheet = false
                    }
                },
                onCancel: {
                    showSaveSelectionSheet = false
                }
            )
        }
        .sheet(item: $pendingRecallSelection) { selection in
            if let result = pendingRecallResult {
                SavedSelectionRecallSheet(
                    selection: selection,
                    result: result,
                    onApply: {
                        processManager.select(result.matched)
                        pendingRecallSelection = nil
                        pendingRecallResult = nil
                    },
                    onCancel: {
                        pendingRecallSelection = nil
                        pendingRecallResult = nil
                    }
                )
            }
        }
        .sheet(item: $renameSelection) { selection in
            RenameSavedSelectionSheet(
                originalName: selection.name,
                name: $renameSelectionName,
                validationError: savedSelections.validationError,
                onSave: {
                    if savedSelections.rename(selection, to: renameSelectionName) {
                        renameSelection = nil
                    }
                },
                onCancel: { renameSelection = nil }
            )
        }
        .sheet(
            item: lifecycleReportBinding
        ) { report in
            LifecycleReportSheet(
                report: report,
                onClose: { processManager.dismissLifecycleReport() }
            )
        }
        .sheet(
            item: batchActionReportBinding
        ) { report in
            ProcessBatchActionReportSheet(
                report: report,
                onClose: { processManager.dismissBatchActionReport() }
            )
        }
        .sheet(item: $quickAutoStopProcess) { process in
            QuickAutoStopRuleSheet(
                process: process,
                existingRule: autoStopRules.rules.first { rule in
                    rule.processName.caseInsensitiveCompare(process.name) == .orderedSame
                },
                onSave: { processName, runtimeMinutes, action in
                    saveQuickAutoStopRule(
                        processName: processName,
                        runtimeMinutes: runtimeMinutes,
                        action: action
                    )
                },
                onCancel: {
                    quickAutoStopProcess = nil
                }
            )
        }
        .sheet(item: $quickPresetDraft) { draft in
            QuickWatchedPresetSheet(
                draft: draft,
                onSave: { preset in
                    saveQuickWatchedPreset(preset)
                },
                onCancel: {
                    quickPresetDraft = nil
                }
            )
        }
        .alert(
            autoStopPromptTitle,
            isPresented: autoStopPromptBinding(for: autoStopRules.currentPrompt),
            presenting: autoStopRules.currentPrompt
        ) { prompt in
            Button("Stop Now", role: .destructive) {
                guard let claimed = autoStopRules.claimPrompt(prompt) else { return }
                Task { await autoStopRules.finishStop(claimed) }
            }
            Button("Dismiss", role: .cancel) {
                autoStopRules.dismissPrompt(prompt)
            }
        } message: { prompt in
            Text("\(prompt.process.name) has run for \(prompt.process.elapsedTime), beyond the \(prompt.rule.runtimeMinutes)-minute rule. Stop it now?")
        }
    }

    private var header: some View {
        TaskScopeHeaderView(
            status: processManager.status,
            samples: history.samples,
            samplingState: history.state,
            showsMetrics: isExpandedWindow,
            showsOpenWindowButton: presentationStyle == .menuBarCompact && openFullWindow != nil,
            openFullWindow: openFullWindow,
            refreshAction: refreshVisibleSection
        )
    }

    private var sectionPicker: some View {
        Picker("Section", selection: Binding(
            get: { settings.selectedSection },
            set: { settings.selectedSectionRaw = $0.rawValue }
        )) {
            ForEach(TaskScopeSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var processList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search processes", text: $settings.searchText)
                    .textFieldStyle(.plain)

                if !settings.searchText.isEmpty {
                    Button {
                        settings.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 8) {
                Picker("Sort", selection: Binding(
                    get: { settings.sortKey },
                    set: { newValue in
                        settings.sortKeyRaw = newValue.rawValue
                        processManager.sortKey = newValue
                    }
                )) {
                    ForEach(ProcessSortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)

                Picker("Filter", selection: $filterMode) {
                    ForEach(ProcessFilterMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                Toggle(isOn: $treeMode) {
                    Label("Tree", systemImage: "list.bullet.indent")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .help("Tree View")

                Menu {
                    if let recoveryMessage = savedSelections.recoveryMessage {
                        Text(recoveryMessage)
                        if savedSelections.isReadOnlyAfterCorruption {
                            // Saving stays disabled until this is pressed, so without
                            // it the user could never save a selection again.
                            Button("Reset Saved Selections After Backup") {
                                savedSelections.resetAfterCorruption()
                            }
                        }
                        Divider()
                    }
                    if savedSelections.selections.isEmpty {
                        Text("No saved selections")
                    } else {
                        ForEach(savedSelections.selections) { sel in
                            Menu(sel.name) {
                                Button("Preview & Recall…") {
                                    pendingRecallResult = savedSelections.resolve(
                                        sel,
                                        in: processManager.inventorySnapshot
                                    )
                                    pendingRecallSelection = sel
                                }
                                Button("Rename…") {
                                    renameSelectionName = sel.name
                                    renameSelection = sel
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    savedSelections.remove(sel)
                                }
                            }
                        }
                        Divider()
                    }
                    if !processManager.selectedPids.isEmpty {
                        Button("Save Current Selection…") {
                            saveSelectionName = ""
            showSaveSelectionSheet = true
                        }
                    }
                } label: {
                    Label("Saved", systemImage: "bookmark")
                        .labelStyle(.iconOnly)
                }
                .help("Saved Selections")

                if !processManager.selectedPids.isEmpty {
                    Button {
                        confirmationState.requestBatch(processManager.selectionSnapshot())
                    } label: {
                        Label("\(processManager.selectedPids.count)", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Button {
                        processManager.clearSelection()
                    } label: {
                        Text("Clear")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()
            }
            .padding(.horizontal, 16)

            HStack {
                Text(processCountTitle)
                if isExpandedWindow {
                    Spacer()
                    Text("PID")
                        .frame(width: 70, alignment: .trailing)
                    Text("PPID")
                        .frame(width: 70, alignment: .trailing)
                    Text("NET KB TOTAL")
                        .frame(width: 96, alignment: .trailing)
                    Text("DISK BLKS TOTAL")
                        .frame(width: 96, alignment: .trailing)
                } else {
                    Spacer()
                }
                Text("CPU")
                    .frame(width: 54, alignment: .trailing)
                Text("MEM MB")
                    .frame(width: 64, alignment: .trailing)
                Text("")
                    .frame(width: 28)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

            if processManager.hasLoadedProcessList, filteredProcesses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: processManager.processLoadError == nil ? "line.3.horizontal.decrease.circle" : "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(processManager.processLoadError == nil ? "No Matching Processes" : "Process List Unavailable")
                        .font(.headline)
                    Text(processManager.processLoadError ?? "Adjust the search or filter to show processes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        if processManager.processLoadError == nil {
                            Button("Clear Search & Filter") {
                                settings.searchText = ""
                                filterMode = .all
                            }
                        }
                        Button("Retry") {
                            Task { await processManager.loadProcessList() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if processManager.hasLoadedProcessList {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if treeMode {
                                ForEach(treeRoots, id: \.id) { node in
                                    ProcessTreeRow(
                                        node: node,
                                        depth: 0,
                                        settings: settings,
                                        processManager: processManager,
                                        keyboardSelectedPid: $keyboardSelectedPid,
                                        pendingTermination: pendingTerminationBinding,
                                        detailProcess: $detailProcess,
                                        detailData: $detailData,
                                        detailFailed: $detailFailed,
                                        expandedPids: $expandedTreePids,
                                        showsExpandedMetrics: isExpandedWindow,
                                        openInActivityMonitor: { openInActivityMonitor(pid: $0) },
                                        contextMenuContent: { process in
                                            processContextMenu(for: process)
                                        }
                                    )
                                }
                            } else {
                                ForEach(filteredProcesses) { process in
                                    processRowView(for: process)
                                        .id(process.pid)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            keyboardSelectedPid = process.pid
                                        }
                                        .contextMenu {
                                            processContextMenu(for: process)
                                        }
                                }
                            }
                        }
                    }
                    .onKeyPress(.upArrow) {
                        moveKeyboard(by: -1, in: keyboardNavigationProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboard(by: 1, in: keyboardNavigationProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let pid = keyboardSelectedPid,
                           let proc = keyboardNavigationProcesses.first(where: { $0.pid == pid }) {
                            confirmationState.requestTermination(proc)
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        processManager.clearSelection()
                        keyboardSelectedPid = nil
                        return .handled
                    }
                    .onKeyPress { keyPress in
                        if keyPress.key == KeyEquivalent("a") && keyPress.modifiers == .command {
                            processManager.select(keyboardNavigationProcesses)
                            return .handled
                        }
                        if keyPress.key == KeyEquivalent("a") && keyPress.modifiers == [.command, .shift] {
                            processManager.clearSelection()
                            return .handled
                        }
                        return .ignored
                    }
                }
            } else {
                LightweightEmptyState {
                    Task {
                        await processManager.loadProcessList()
                    }
                }
            }
        }
    }

    private var presetsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(processManager.snapshots) { snapshot in
                    PresetCard(
                        snapshot: snapshot,
                        onOpen: {
                            Task {
                                _ = await AppCommandBus.shared.submit(
                                    .openPreset(snapshot.preset.displayName)
                                )
                            }
                        },
                        onQuitApp: {
                            confirmationState.requestPresetAction(.quitApp, preset: snapshot.preset)
                        },
                        onQuitHelpers: {
                            confirmationState.requestPresetAction(.quitHelpers, preset: snapshot.preset)
                        },
                        onQuitAll: {
                            confirmationState.requestPresetAction(.quitAll, preset: snapshot.preset)
                        }
                    )
                }

                if processManager.snapshots.isEmpty {
                    Text("No watched apps configured. Add presets in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { loginItemManager.isEnabled },
                        set: { loginItemManager.setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .padding(.top, 4)

                if let loginMessage = loginItemManager.message {
                    Text(loginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if loginItemManager.state == .requiresApproval {
                    Button("Open Login Item Settings") {
                        loginItemManager.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        TaskScopeFooterView(
            isWorking: processManager.isWorking,
            message: processManager.message,
            summary: footerSummary,
            quitAction: { NSApplication.shared.terminate(nil) }
        )
    }

    private var filteredProcesses: [AppProcess] {
        let trimmedSearch = settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let watchedNames = Set(processManager.snapshots.flatMap { $0.preset.allProcessNames })

        return processManager.displayProcesses { process in
            let matchesSearch = trimmedSearch.isEmpty
                || process.name.localizedCaseInsensitiveContains(trimmedSearch)
                || process.command.localizedCaseInsensitiveContains(trimmedSearch)
                || String(process.pid).contains(trimmedSearch)
            guard matchesSearch else { return false }

            switch filterMode {
            case .all:
                return true
            case .watched:
                return watchedNames.contains(process.name)
            case .highlighted:
                return process.cpu >= settings.cpuHighlightThreshold
                    || process.memoryMB >= settings.memHighlightThresholdMB
            }
        }
    }

    private var processCountTitle: String {
        if !processManager.hasLoadedProcessList {
            return "Not loaded"
        }

        let hasSearch = !settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSearch ? "\(filteredProcesses.count) matches" : "\(filteredProcesses.count) processes"
    }

    private func refreshVisibleSection() {
        Task {
            switch settings.selectedSection {
            case .processes:
                await processManager.loadProcessList()
            case .presets:
                _ = await AppCommandBus.shared.submit(.refresh)
            }
        }
    }

    private func openInActivityMonitor(pid: Int32) {
        Task {
            let outcome = await activityMonitor.openAndSelect(pid: pid)
            processManager.setMessage(outcome.message(for: pid))
        }
    }

    private var footerSummary: String? {
        guard processManager.hasLoadedProcessList, !filteredProcesses.isEmpty else { return nil }
        let totalCPU = filteredProcesses.reduce(0.0) { $0 + $1.cpu }
        let totalMem = filteredProcesses.reduce(0.0) { $0 + $1.memoryMB }
        return String(format: "Σ %.1f%% CPU · %.0f MB MEM", totalCPU, totalMem)
    }

    private var treeRoots: [ProcessTreeNode] {
        let matchingPIDs = Set(filteredProcesses.map(\.pid))
        return ProcessTreeBuilder.build(
            from: processManager.inventorySnapshot,
            ppidMap: processManager.ppidMap,
            matchingPIDs: matchingPIDs
        )
    }

    private var keyboardNavigationProcesses: [AppProcess] {
        guard treeMode else { return filteredProcesses }
        return visibleTreeProcesses
    }

    private var visibleTreeProcesses: [AppProcess] {
        func flatten(_ nodes: [ProcessTreeNode]) -> [AppProcess] {
            nodes.flatMap { node in
                var visible = [node.process]
                if expandedTreePids.contains(node.process.pid) {
                    visible.append(contentsOf: flatten(node.children))
                }
                return visible
            }
        }
        return flatten(treeRoots)
    }

    private var renderedSelectionProcesses: [AppProcess] {
        treeMode ? visibleTreeProcesses : filteredProcesses
    }

    private var renderedProcessIdentities: [ProcessIdentity] {
        renderedSelectionProcesses.map(\.identity)
    }

    private var pendingTerminationBinding: Binding<AppProcess?> {
        Binding(
            get: { confirmationState.pendingTermination },
            set: { process in
                if let process {
                    confirmationState.requestTermination(process)
                } else {
                    confirmationState.clearTermination()
                }
            }
        )
    }

    private var autoStopPromptTitle: String {
        guard let processName = autoStopRules.currentPrompt?.process.name else {
            return "Auto-Stop"
        }
        return "Auto-Stop: \(processName)"
    }

    private var lifecycleReportBinding: Binding<LifecycleReport?> {
        Binding(
            get: { processManager.lifecycleReport },
            set: { value in
                if value == nil {
                    processManager.dismissLifecycleReport()
                }
            }
        )
    }

    private var batchActionReportBinding: Binding<ProcessBatchActionReport?> {
        Binding(
            get: { processManager.batchActionReport },
            set: { value in
                if value == nil {
                    processManager.dismissBatchActionReport()
                }
            }
        )
    }

    private func expandFilteredTreeAncestors() {
        let isFiltering = !settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filterMode != .all
        guard treeMode, isFiltering else { return }

        func collectParents(_ nodes: [ProcessTreeNode]) {
            for node in nodes {
                if !node.children.isEmpty {
                    expandedTreePids.insert(node.process.pid)
                    collectParents(node.children)
                }
            }
        }
        collectParents(treeRoots)
    }

    @ViewBuilder
    private func processRowView(for process: AppProcess) -> some View {
        ProcessRow(
            process: process,
            isCurrentProcess: processManager.isCurrentProcess(process),
            isSelected: processManager.selectedPids.contains(process.pid),
            isKeyboardSelected: keyboardSelectedPid == process.pid,
            isHighlightedCPU: process.cpu >= settings.cpuHighlightThreshold,
            isHighlightedMEM: process.memoryMB >= settings.memHighlightThresholdMB,
            showsExpandedMetrics: isExpandedWindow,
            stopAction: { confirmationState.requestTermination(process) },
            toggleSelection: { processManager.toggleSelection(process.pid) },
            detailAction: {
                detailData = nil
                detailProcess = process
            },
            forceStopAction: {
                confirmationState.requestTermination(process)
            },
            copyCommandAction: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.command, forType: .string)
            }
        )
    }

    @ViewBuilder
    private func processContextMenu(for process: AppProcess) -> some View {
        Button("Create Auto-Stop Rule...") {
            quickAutoStopProcess = process
        }
        Button("Watch This Process...") {
            quickPresetDraft = QuickWatchedPresetDraft(processes: [process])
        }
        if !processManager.selectedPids.isEmpty {
            Button("Save Selection as Preset...") {
                quickPresetDraft = QuickWatchedPresetDraft(processes: selectedProcessesForPreset())
            }
        }
        Divider()
        Button("Stop") { confirmationState.requestTermination(process) }
        Button("Force Stop") {
            confirmationState.requestTermination(process)
        }
        Divider()
        Button("Show Detail") {
            detailData = nil
            detailFailed = false
            detailProcess = process
        }
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(process.command, forType: .string)
        }
        Divider()
        Button("Open in Activity Monitor") {
            openInActivityMonitor(pid: process.pid)
        }
    }

    private func presetConfirmationMessage(
        for pending: ProcessConfirmationState.PendingPresetAction
    ) -> String {
        let names: [String]
        switch pending.action {
        case .quitApp:
            names = [pending.preset.mainProcessName]
        case .quitHelpers:
            names = pending.preset.helperProcessNames
        case .quitAll:
            names = pending.preset.killableNames
        }
        let targets = names.isEmpty ? "no configured processes" : names.joined(separator: ", ")
        return "TaskScope will stop the currently running matches for: \(targets)."
    }

    private func moveKeyboard(by delta: Int, in processes: [AppProcess], proxy: ScrollViewProxy) {
        guard !processes.isEmpty else { return }
        let current = keyboardSelectedPid
        var index = processes.firstIndex(where: { $0.pid == current }) ?? -1
        index = max(0, min(processes.count - 1, index + delta))
        let target = processes[index]
        keyboardSelectedPid = target.pid
        proxy.scrollTo(target.pid, anchor: .center)
    }

    /// Binds presentation to one specific prompt, captured when the alert was built.
    ///
    /// The write-back must dismiss *that* prompt, never `currentPrompt`: a button
    /// action claims its prompt synchronously and the queue head has already moved
    /// on by the time SwiftUI sets `isPresented = false`, so resolving the head here
    /// would consume a second prompt the user never saw. Dismissal is idempotent, so
    /// for a button tap this is a no-op and for Esc / click-away it does the work.
    private func autoStopPromptBinding(for prompt: AutoStopPrompt?) -> Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { isPresented in
                if !isPresented, let prompt {
                    autoStopRules.dismissPrompt(prompt)
                }
            }
        )
    }

    private func selectedProcessesForPreset() -> [AppProcess] {
        // Must come from the full inventory, not the display slice: a row surfaced
        // by the search filter can rank below the display limit, so filtering
        // `processManager.processes` would silently drop it from the draft.
        processManager.selectedProcessesSnapshot()
    }

    private func saveQuickAutoStopRule(
        processName: String,
        runtimeMinutes: Int,
        action: AutoStopRule.Action
    ) {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if let existing = autoStopRules.rules.first(where: {
            $0.processName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            _ = autoStopRules.update(AutoStopRule(
                id: existing.id,
                processName: trimmedName,
                runtimeMinutes: runtimeMinutes,
                action: action,
                isEnabled: existing.isEnabled
            ))
            processManager.setMessage("Updated auto-stop rule for \(trimmedName).")
        } else {
            autoStopRules.add(
                AutoStopRule(
                    processName: trimmedName,
                    runtimeMinutes: runtimeMinutes,
                    action: action
                )
            )
            processManager.setMessage("Added auto-stop rule for \(trimmedName).")
        }

        quickAutoStopProcess = nil
    }

    private func saveQuickWatchedPreset(_ preset: WatchedAppPreset) {
        if watchedApps.presets.contains(where: {
            $0.mainProcessName.caseInsensitiveCompare(preset.mainProcessName) == .orderedSame
        }) {
            processManager.setMessage("\(preset.mainProcessName) is already watched.")
        } else {
            watchedApps.add(preset)
            processManager.setMessage("Watching \(preset.displayName).")
            // No refresh here: the app's `.onChange(of: watchedApps.presets)` handler
            // is the single owner of preset-change refreshes. A second one raced it
            // and was either coalesced away or ran first and diffed the new preset's
            // already-running process against a baseline that never contained it.
        }

        quickPresetDraft = nil
    }
}
