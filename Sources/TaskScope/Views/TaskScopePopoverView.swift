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

struct TaskScopePopoverView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var savedSelections: SavedSelectionsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    var presentationStyle: TaskScopePresentationStyle = .menuBarCompact
    var openFullWindow: (() -> Void)?

    @StateObject private var history = ProcessHistory()

    @State private var pendingTermination: AppProcess?
    @State private var pendingBatch: Bool = false
    @State private var detailProcess: AppProcess?
    @State private var detailData: ProcessDetail?
    @State private var detailFailed: Bool = false
    @State private var keyboardSelectedPid: Int32?
    @State private var filterMode: ProcessFilterMode = .all
    @State private var treeMode: Bool = false
    @State private var saveSelectionName: String = ""
    @State private var showSaveSelectionSheet: Bool = false
    @State private var autoStopTarget: AutoStopRule?
    @State private var autoStopProcess: AppProcess?
    @State private var quickAutoStopProcess: AppProcess?
    @State private var quickPresetDraft: QuickWatchedPresetDraft?

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
        .task {
            loginItemManager.refresh()
            processManager.watchedAppsProvider = { watchedApps.presets }
            processManager.processListLimitProvider = { settings.processListLimit }
            processManager.sortKey = settings.sortKey
            processManager.enableNotifications = settings.enableNotifications
            processManager.setPolling(
                interval: settings.refreshIntervalSeconds,
                includeProcessList: settings.autoRefreshProcessList
            )
            await processManager.refreshWatchedStatus(showMessage: false)

            if settings.enableNotifications {
                await NotificationService.shared.requestAuthorization()
                let running = Set(processManager.snapshots.flatMap { $0.runningNames })
                NotificationService.shared.prime(initialRunningNames: running)
            }
        }
        .onChange(of: settings.refreshIntervalSeconds) { _, _ in
            processManager.setPolling(
                interval: settings.refreshIntervalSeconds,
                includeProcessList: settings.autoRefreshProcessList
            )
        }
        .onChange(of: settings.autoRefreshProcessList) { _, _ in
            processManager.setPolling(
                interval: settings.refreshIntervalSeconds,
                includeProcessList: settings.autoRefreshProcessList
            )
        }
        .onChange(of: settings.enableNotifications) { _, newValue in
            processManager.enableNotifications = newValue
            if newValue {
                Task {
                    await NotificationService.shared.requestAuthorization()
                    let running = Set(processManager.snapshots.flatMap { $0.runningNames })
                    NotificationService.shared.prime(initialRunningNames: running)
                }
            }
        }
        .onChange(of: watchedApps.presets) { _, _ in
            Task { await processManager.refreshWatchedStatusUnchecked(showMessage: false) }
        }
        .onChange(of: processManager.processes) { _, newProcesses in
            if let pid = keyboardSelectedPid, !newProcesses.contains(where: { $0.pid == pid }) {
                keyboardSelectedPid = nil
            }
            history.record(processes: newProcesses)
            evaluateAutoStopRules(newProcesses)
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskScopeRefreshRequested)) { _ in
            Task { await processManager.refreshWatchedStatus(showMessage: true) }
        }
        .confirmationDialog(
            "Stop Process?",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingTermination = nil
                    }
                }
            ),
            presenting: pendingTermination
        ) { process in
            Button("Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process) }
                pendingTermination = nil
            }

            Button("Force Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process, forceKill: true) }
                pendingTermination = nil
            }

            Button("Cancel", role: .cancel) {
                pendingTermination = nil
            }
        } message: { process in
            Text("Send a normal quit signal to PID \(process.pid). Force Stop sends an immediate kill signal if the process does not respond.")
        }
        .confirmationDialog(
            "Stop Selected Processes?",
            isPresented: $pendingBatch
        ) {
            Button("Stop Selected", role: .destructive) {
                Task { await processManager.batchTerminate() }
                pendingBatch = false
            }
            Button("Force Stop Selected", role: .destructive) {
                Task { await processManager.batchTerminate(forceKill: true) }
                pendingBatch = false
            }
            Button("Cancel", role: .cancel) {
                pendingBatch = false
            }
        } message: {
            Text("Stop \(processManager.selectedPids.count) selected processes.")
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
                onSave: {
                    let selectedProcesses = processManager.processes.filter {
                        processManager.selectedPids.contains($0.pid)
                    }
                    savedSelections.save(name: saveSelectionName, processes: selectedProcesses)
                    showSaveSelectionSheet = false
                },
                onCancel: {
                    showSaveSelectionSheet = false
                }
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
            "Auto-Stop: \(autoStopProcess?.name ?? "")",
            isPresented: Binding(
                get: { autoStopTarget != nil },
                set: { if !$0 { autoStopTarget = nil; autoStopProcess = nil } }
            ),
            presenting: autoStopProcess
        ) { process in
            Button("Stop Now", role: .destructive) {
                Task { await processManager.terminate(process) }
                autoStopTarget = nil
                autoStopProcess = nil
            }
            Button("Dismiss", role: .cancel) {
                autoStopTarget = nil
                autoStopProcess = nil
            }
        } message: { process in
            Text("\(process.name) has been running longer than the auto-stop rule (\(autoStopTarget?.runtimeMinutes ?? 0) min). Stop it now?")
        }
    }

    private var header: some View {
        TaskScopeHeaderView(
            status: processManager.status,
            samples: history.samples,
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
                    if savedSelections.selections.isEmpty {
                        Text("No saved selections")
                    } else {
                        ForEach(savedSelections.selections) { sel in
                            Button(sel.name) {
                                processManager.clearSelection()
                                for process in processManager.processes where sel.matches(process) {
                                    processManager.toggleSelection(process.pid)
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
                        pendingBatch = true
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
                    Text("NET KB")
                        .frame(width: 96, alignment: .trailing)
                    Text("DISK")
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

            if processManager.hasLoadedProcessList {
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
                                        pendingTermination: $pendingTermination,
                                        detailProcess: $detailProcess,
                                        detailData: $detailData,
                                        detailFailed: $detailFailed,
                                        showsExpandedMetrics: isExpandedWindow,
                                        openInActivityMonitor: { openInActivityMonitor(pid: $0) }
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
                        moveKeyboard(by: -1, in: filteredProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboard(by: 1, in: filteredProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let pid = keyboardSelectedPid,
                           let proc = filteredProcesses.first(where: { $0.pid == pid }) {
                            pendingTermination = proc
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
                            processManager.selectAll()
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
                        onOpen: { Task { await processManager.openApp(snapshot.preset) } },
                        onQuitApp: { Task { await processManager.quitMainApp(snapshot.preset) } },
                        onQuitHelpers: { Task { await processManager.quitHelpers(snapshot.preset) } },
                        onQuitAll: { Task { await processManager.quitAllKillable(snapshot.preset) } }
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

        let searched: [AppProcess]
        if trimmedSearch.isEmpty {
            searched = processManager.processes
        } else {
            searched = processManager.processes.filter { process in
                process.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                    process.command.localizedCaseInsensitiveContains(trimmedSearch) ||
                    String(process.pid).contains(trimmedSearch)
            }
        }

        switch filterMode {
        case .all:
            return searched
        case .watched:
            let watchedNames = Set(processManager.snapshots.flatMap { $0.preset.allProcessNames })
            return searched.filter { watchedNames.contains($0.name) }
        case .highlighted:
            return searched.filter {
                $0.cpu >= settings.cpuHighlightThreshold ||
                $0.memoryMB >= settings.memHighlightThresholdMB
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
                await processManager.refreshWatchedStatus()
            }
        }
    }

    private func openInActivityMonitor(pid: Int32) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, openError in
            if let openError {
                DispatchQueue.main.async {
                    processManager.setMessage("Could not open Activity Monitor: \(openError.localizedDescription)")
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let script = "tell application \"Activity Monitor\" to set selected processes to (every process whose unix id is \(pid))"
                guard let appleScript = NSAppleScript(source: script) else { return }
                var err: NSDictionary?
                appleScript.executeAndReturnError(&err)
                if let err {
                    let message = err[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    DispatchQueue.main.async {
                        processManager.setMessage("Activity Monitor selection failed: \(message)")
                    }
                }
            }
        }
    }

    private var footerSummary: String? {
        guard processManager.hasLoadedProcessList, !filteredProcesses.isEmpty else { return nil }
        let totalCPU = filteredProcesses.reduce(0.0) { $0 + $1.cpu }
        let totalMem = filteredProcesses.reduce(0.0) { $0 + $1.memoryMB }
        return String(format: "Σ %.1f%% CPU · %.0f MB MEM", totalCPU, totalMem)
    }

    private var treeRoots: [ProcessTreeNode] {
        ProcessTreeBuilder.build(from: filteredProcesses, ppidMap: processManager.ppidMap)
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
            stopAction: { pendingTermination = process },
            toggleSelection: { processManager.toggleSelection(process.pid) },
            detailAction: {
                detailData = nil
                detailProcess = process
            },
            forceStopAction: {
                Task { await processManager.terminate(process, forceKill: true) }
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
        Button("Stop") { pendingTermination = process }
        Button("Force Stop") {
            Task { await processManager.terminate(process, forceKill: true) }
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

    private func moveKeyboard(by delta: Int, in processes: [AppProcess], proxy: ScrollViewProxy) {
        guard !processes.isEmpty else { return }
        let current = keyboardSelectedPid
        var index = processes.firstIndex(where: { $0.pid == current }) ?? -1
        index = max(0, min(processes.count - 1, index + delta))
        let target = processes[index]
        keyboardSelectedPid = target.pid
        proxy.scrollTo(target.pid, anchor: .center)
    }

    private func evaluateAutoStopRules(_ processes: [AppProcess]) {
        autoStopRules.evaluate(runningProcesses: processes) { rule, process in
            switch rule.action {
            case .prompt:
                autoStopTarget = rule
                autoStopProcess = process
            case .kill:
                Task { await processManager.terminate(process) }
            case .silent:
                break
            }
        }
    }

    private func selectedProcessesForPreset() -> [AppProcess] {
        processManager.processes.filter { processManager.selectedPids.contains($0.pid) }
    }

    private func saveQuickAutoStopRule(
        processName: String,
        runtimeMinutes: Int,
        action: AutoStopRule.Action
    ) {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if let index = autoStopRules.rules.firstIndex(where: {
            $0.processName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            autoStopRules.rules[index] = AutoStopRule(
                id: autoStopRules.rules[index].id,
                processName: trimmedName,
                runtimeMinutes: runtimeMinutes,
                action: action
            )
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
            Task { await processManager.refreshWatchedStatus(showMessage: false) }
        }

        quickPresetDraft = nil
    }
}
