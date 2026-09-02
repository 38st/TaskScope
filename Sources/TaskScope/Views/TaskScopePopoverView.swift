import AppKit
import SwiftUI

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
        autoStopAlertContent
    }

    private var baseContent: some View {
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
    }

    private var observedContent: some View {
        baseContent
        .onAppear {
            guard isExpandedWindow, !registeredExtendedMetrics else { return }
            registeredExtendedMetrics = true
            history.beginSampling(cadence: settings.refreshIntervalSeconds)
            Task { await processManager.beginExtendedMetrics() }
        }
        .onDisappear {
            guard registeredExtendedMetrics else { return }
            registeredExtendedMetrics = false
            history.endSampling()
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
    }

    private var terminationConfirmationContent: some View {
        observedContent
        .confirmationDialog(
            confirmationState.pendingTermination?.mode.title ?? "Stop Process?",
            isPresented: terminationConfirmationBinding,
            presenting: confirmationState.pendingTermination
        ) { pending in
            Button(
                pending.mode == .force
                    ? "Force Stop \(pending.process.name)"
                    : "Stop \(pending.process.name)",
                role: .destructive
            ) {
                let process = pending.process
                let forceKill = pending.mode == .force
                Task { await processManager.terminate(process, forceKill: forceKill) }
                confirmationState.clearTermination()
            }

            Button("Cancel", role: .cancel) {
                confirmationState.clearTermination()
            }
        } message: { pending in
            if pending.mode == .force {
                Text("Immediately send a kill signal to PID \(pending.process.pid). The process cannot clean up before it exits.")
            } else {
                Text("Send a normal quit signal to PID \(pending.process.pid), allowing the process to clean up before it exits.")
            }
        }
        .confirmationDialog(
            confirmationState.pendingBatchTermination?.mode == .force
                ? "Force Stop Selected Processes?"
                : "Stop Selected Processes?",
            isPresented: batchConfirmationBinding,
            presenting: confirmationState.pendingBatchTermination
        ) { pending in
            Button(
                pending.mode == .force ? "Force Stop Selected" : "Stop Selected",
                role: .destructive
            ) {
                let targets = pending.targets
                let forceKill = pending.mode == .force
                Task { await processManager.batchTerminate(targets, forceKill: forceKill) }
                confirmationState.clearBatch()
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearBatch()
            }
        } message: { _ in
            Text(confirmationState.batchMessage)
        }
    }

    private var presetConfirmationContent: some View {
        terminationConfirmationContent
        .confirmationDialog(
            confirmationState.pendingPresetAction?.action.rawValue ?? "Confirm Preset Action",
            isPresented: presetConfirmationBinding,
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
                    case .keepOff:
                        _ = await processManager.keepOff(preset)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearPresetAction()
            }
        } message: { pending in
            Text(presetConfirmationMessage(for: pending))
        }
    }

    private var processDetailContent: some View {
        presetConfirmationContent
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
    }

    private var savedSelectionSheetContent: some View {
        processDetailContent
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
    }

    private var reportSheetContent: some View {
        savedSelectionSheetContent
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
    }

    private var quickActionSheetContent: some View {
        reportSheetContent
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
    }

    private var autoStopAlertContent: some View {
        quickActionSheetContent
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
                    .accessibilityLabel("Clear process search")
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
                .accessibilityLabel("Tree view")
                .accessibilityValue(treeMode ? "On" : "Off")

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
                .accessibilityLabel("Saved selections")

                if !processManager.selectedPids.isEmpty {
                    Menu {
                        Button("Stop Selected…", role: .destructive) {
                            confirmationState.requestBatch(
                                processManager.selectionSnapshot(),
                                mode: .normal
                            )
                        }
                        Button("Force Stop Selected…", role: .destructive) {
                            confirmationState.requestBatch(
                                processManager.selectionSnapshot(),
                                mode: .force
                            )
                        }
                    } label: {
                        Label("\(processManager.selectedPids.count)", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel(
                        "Actions for \(processManager.selectedPids.count) selected processes"
                    )

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

            if processManager.hasLoadedProcessList,
               let processLoadError = processManager.processLoadError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Process list is stale")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(staleProcessListDetail(error: processLoadError))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Retry") {
                        Task { await processManager.loadProcessList() }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)
            }

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
                    Text("DISK MB TOTAL")
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
        PresetsSectionView(
            processManager: processManager,
            loginItemManager: loginItemManager,
            settings: settings,
            confirmationState: confirmationState
        )
    }

    private var footer: some View {
        TaskScopeFooterView(
            isWorking: processManager.isWorking,
            message: processManager.message,
            summary: footerSummary,
            quitAction: { NSApplication.shared.terminate(nil) }
        )
    }

    private var listQuery: ProcessListQuery {
        ProcessListQuery(
            searchText: settings.searchText,
            filterMode: filterMode,
            watchedNames: Set(processManager.snapshots.flatMap { $0.preset.allProcessNames }),
            cpuHighlightThreshold: settings.cpuHighlightThreshold,
            memoryHighlightThresholdMB: settings.memHighlightThresholdMB
        )
    }

    /// Memoized by the manager per inventory generation, so the several reads
    /// SwiftUI makes during one body pass compute the list once.
    private var filteredProcesses: [AppProcess] {
        processManager.displayProcesses(for: listQuery)
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
        processManager.treeRoots(for: listQuery)
    }

    private var keyboardNavigationProcesses: [AppProcess] {
        guard treeMode else { return filteredProcesses }
        return visibleTreeProcesses
    }

    private var visibleTreeProcesses: [AppProcess] {
        ProcessTreeBuilder.visibleProcesses(
            in: treeRoots,
            expandedPIDs: expandedTreePids
        )
    }

    private var renderedSelectionProcesses: [AppProcess] {
        treeMode ? visibleTreeProcesses : filteredProcesses
    }

    private var renderedProcessIdentities: [ProcessIdentity] {
        renderedSelectionProcesses.map(\.identity)
    }

    private var terminationConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmationState.pendingTermination != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearTermination()
                }
            }
        )
    }

    private var pendingTerminationBinding: Binding<AppProcess?> {
        Binding(
            get: { confirmationState.pendingTermination?.process },
            set: { process in
                if let process {
                    confirmationState.requestTermination(process)
                } else {
                    confirmationState.clearTermination()
                }
            }
        )
    }

    private var batchConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmationState.pendingBatchTermination != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearBatch()
                }
            }
        )
    }

    private var presetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmationState.pendingPresetAction != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearPresetAction()
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
                confirmationState.requestTermination(process, mode: .force)
            },
            copyCommandAction: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    process.executablePath ?? process.command,
                    forType: .string
                )
            }
        )
    }

    private func staleProcessListDetail(error: String) -> String {
        let lastUpdated: String
        if let date = processManager.lastSuccessfulInventoryAt {
            lastUpdated = "Last updated \(date.formatted(date: .omitted, time: .standard))."
        } else {
            lastUpdated = "The last successful update time is unavailable."
        }
        return "\(lastUpdated) Refresh failed: \(error) Actions will be revalidated before signaling."
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
            confirmationState.requestTermination(process, mode: .force)
        }
        Divider()
        Button("Show Detail") {
            detailData = nil
            detailFailed = false
            detailProcess = process
        }
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                process.executablePath ?? process.command,
                forType: .string
            )
        }
        Divider()
        Button("Open in Activity Monitor") {
            openInActivityMonitor(pid: process.pid)
        }
    }

    private func presetConfirmationMessage(
        for pending: ProcessConfirmationState.PendingPresetAction
    ) -> String {
        Self.presetConfirmationMessage(for: pending)
    }

    /// Spells out every side effect of a preset action: which launch agents are
    /// unloaded and which processes are signalled. Quit Helpers keeps an agent
    /// loaded when it is the one running the main process.
    static func presetConfirmationMessage(
        for pending: ProcessConfirmationState.PendingPresetAction
    ) -> String {
        let preset = pending.preset
        let names: [String]
        switch pending.action {
        case .quitApp:
            names = [preset.mainProcessName]
        case .quitHelpers:
            names = preset.helperProcessNames
        case .quitAll:
            names = preset.killableNames
        case .keepOff:
            names = preset.killableNames
        }
        let targets = names.isEmpty ? "no configured processes" : names.joined(separator: ", ")
        let agentLabels = preset.lifecycleUserLaunchAgentJobs.map(\.label)
        let agentList = agentLabels.joined(separator: ", ")
        let window = Int(ProcessTerminationController.gracefulExitWindowSeconds)
        let forceStopDisclosure = "A process still running \(window) seconds after the stop request is force stopped."

        var sentences: [String] = []
        switch pending.action {
        case .keepOff:
            sentences.append(
                "TaskScope will persistently disable GlobalProtect's per-user launch agents (\(agentList)) and stop current user-facing matches: \(targets)."
            )
            sentences.append("A protected system daemon, if installed, remains untouched.")
        case .quitHelpers:
            if !agentLabels.isEmpty {
                sentences.append(
                    "TaskScope will unload the helper launch agents (\(agentList)); an agent that is running the main \(preset.mainProcessName) process is left loaded."
                )
            }
            sentences.append("It will then stop the currently running matches for: \(targets).")
        case .quitApp, .quitAll:
            if !agentLabels.isEmpty {
                sentences.append("TaskScope will unload the user launch agents (\(agentList)).")
            }
            sentences.append("It will then stop the currently running matches for: \(targets).")
        }
        sentences.append(forceStopDisclosure)
        return sentences.joined(separator: " ")
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
    ) -> String? {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Process name is required." }
        let observedExecutablePath = quickAutoStopProcess?.executablePath

        if let existing = autoStopRules.rules.first(where: {
            $0.processName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            guard autoStopRules.update(AutoStopRule(
                id: existing.id,
                processName: trimmedName,
                executablePath: observedExecutablePath ?? existing.executablePath,
                runtimeMinutes: runtimeMinutes,
                action: action,
                isEnabled: existing.isEnabled
            )) else {
                return autoStopRules.validationError ?? "The auto-stop rule could not be updated."
            }
            processManager.setMessage("Updated auto-stop rule for \(trimmedName).")
        } else {
            guard autoStopRules.add(
                AutoStopRule(
                    processName: trimmedName,
                    executablePath: observedExecutablePath,
                    runtimeMinutes: runtimeMinutes,
                    action: action
                )
            ) else {
                return autoStopRules.validationError ?? "The auto-stop rule could not be added."
            }
            processManager.setMessage("Added auto-stop rule for \(trimmedName).")
        }

        quickAutoStopProcess = nil
        return nil
    }

    private func saveQuickWatchedPreset(_ preset: WatchedAppPreset) -> String? {
        if watchedApps.presets.contains(where: {
            $0.mainProcessName.caseInsensitiveCompare(preset.mainProcessName) == .orderedSame
        }) {
            return "\(preset.mainProcessName) is already watched."
        }

        guard watchedApps.add(preset) else {
            return watchedApps.validationError
                ?? watchedApps.persistenceIssue
                ?? "TaskScope could not save this watched preset."
        }

        processManager.setMessage("Watching \(preset.displayName).")
        // No refresh here: the app's `.onChange(of: watchedApps.presets)` handler
        // is the single owner of preset-change refreshes. A second one raced it
        // and was either coalesced away or ran first and diffed the new preset's
        // already-running process against a baseline that never contained it.
        quickPresetDraft = nil
        return nil
    }
}
