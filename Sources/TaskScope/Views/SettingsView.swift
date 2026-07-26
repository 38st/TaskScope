import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    @ObservedObject private var notificationService = NotificationService.shared

    @State private var newDisplayName = ""
    @State private var newMainProcess = ""
    @State private var newHelpers = ""
    @State private var newProtected = ""
    @State private var newAppPath = "/Applications/"
    @State private var newAgentLabels = ""
    @State private var newAgentPlistPaths = ""
    @State private var newDaemonLabels = ""
    @State private var newDaemonPlistPaths = ""
    @State private var newDaemonProcessNames = ""
    @State private var newDaemonPorts = ""
    @State private var newRuleName = ""
    @State private var newRuleMinutes = 5
    @State private var newRuleAction: AutoStopRule.Action = .prompt
    @State private var editingRule: AutoStopRule?
    @State private var exportError: String?
    @State private var importError: String?
    @State private var presetValidationError: String?
    @State private var showImporter = false
    @State private var showPresetEditor = false
    @State private var editingPresetID: UUID?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            watchedAppsTab.tabItem { Label("Watched Apps", systemImage: "shield.lefthalf.filled") }
            autoStopTab.tabItem { Label("Auto-Stop", systemImage: "timer") }
            hotkeyTab.tabItem { Label("Hotkey", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 540)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importPresets(from: url)
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        .sheet(item: $editingRule) { rule in
            AutoStopRuleEditorSheet(
                rule: rule,
                onSave: { updated in
                    if autoStopRules.update(updated) {
                        editingRule = nil
                    }
                },
                onCancel: { editingRule = nil }
            )
        }
        .sheet(isPresented: $showPresetEditor) {
            presetEditorSheet
        }
    }

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                HStack {
                    Text("Watched status interval")
                    Spacer()
                    Slider(value: $settings.refreshIntervalSeconds, in: 2...60, step: 1)
                    Text("\(Int(settings.refreshIntervalSeconds))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("Auto-refresh process list", isOn: $settings.autoRefreshProcessList)
                Stepper(value: $settings.processListLimit, in: 10...200, step: 10) {
                    HStack {
                        Text("Process list limit")
                        Spacer()
                        Text("\(settings.processListLimit)").monospacedDigit()
                    }
                }
            }

            Section("Highlight Thresholds") {
                HStack {
                    Text("CPU %")
                    Spacer()
                    Slider(value: $settings.cpuHighlightThreshold, in: 1...100, step: 1)
                    Text(String(format: "%.0f%%", settings.cpuHighlightThreshold))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Memory (MB)")
                    Spacer()
                    Slider(value: $settings.memHighlightThresholdMB, in: 100...8192, step: 64)
                    Text(String(format: "%.0f", settings.memHighlightThresholdMB))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            Section("Notifications") {
                Toggle("Notify on watched process changes", isOn: $settings.enableNotifications)
                LabeledContent("System permission", value: notificationService.authorizationState.label)
                if notificationService.authorizationState == .denied {
                    Button("Open Notification Settings") {
                        notificationService.openSystemSettings()
                    }
                }
                Text("TaskScope shows foreground banners without sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let recoveryMessage = settings.recoveryMessage {
                Section("Recovered Settings") {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var watchedAppsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Watched Apps").font(.headline)
                Spacer()
                Button {
                    prepareNewPreset()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button {
                    exportPresets()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            .padding(.horizontal)

            if let issue = watchedApps.persistenceIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Reset Presets After Backup", role: .destructive) {
                        watchedApps.resetAfterCorruption()
                    }
                }
                .padding(.horizontal)
            }

            List {
                ForEach(watchedApps.presets) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(preset.displayName).fontWeight(.semibold)
                            Spacer()
                            Button("Edit") {
                                prepareToEdit(preset)
                            }
                            .buttonStyle(.borderless)
                            Toggle("", isOn: Binding(
                                get: { preset.notificationsEnabled },
                                set: { newValue in
                                    var updated = preset
                                    updated.notificationsEnabled = newValue
                                    watchedApps.update(updated)
                                }
                            ))
                            .labelsHidden()
                            .help("Notifications for this preset")
                        }
                        Text("Main: \(preset.mainProcessName)").font(.caption).foregroundStyle(.secondary)
                        Text("Helpers: \(preset.helperProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        Text("Protected: \(preset.protectedProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        Text("App path: \(preset.appPath)").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    watchedApps.presets.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { watchedApps.remove(at: $0) }
            }

            if let err = importError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            if let err = exportError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private var presetEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingPresetID == nil ? "Add Watched App" : "Edit Watched App")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextFieldRow(label: "Display name", text: $newDisplayName)
                    TextFieldRow(label: "Main process name", text: $newMainProcess)
                    TextFieldRow(label: "Helpers (comma-separated)", text: $newHelpers)
                    TextFieldRow(label: "Protected (comma-separated)", text: $newProtected)
                    TextFieldRow(label: "App bundle path", text: $newAppPath)

                    Divider().padding(.vertical, 4)
                    Text("Launch Agents (optional)").font(.headline)
                    TextFieldRow(label: "Labels", text: $newAgentLabels)
                    TextFieldRow(label: "Plist paths", text: $newAgentPlistPaths)

                    Divider().padding(.vertical, 4)
                    Text("System Launch Daemons (optional)").font(.headline)
                    TextFieldRow(label: "Labels", text: $newDaemonLabels)
                    TextFieldRow(label: "Plist paths", text: $newDaemonPlistPaths)
                    TextFieldRow(label: "Process names", text: $newDaemonProcessNames)
                    TextFieldRow(label: "Ports (blank allowed)", text: $newDaemonPorts)
                }
            }

            if let error = presetValidationError ?? watchedApps.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showPresetEditor = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(editingPresetID == nil ? "Add Preset" : "Save Changes") {
                    savePresetEditor()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newMainProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }

    private var autoStopTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(autoStopRules.recoveryMessages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            List {
                Section("Rules") {
                    ForEach(autoStopRules.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { autoStopRules.setEnabled($0, for: rule) }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.processName).fontWeight(.medium)
                                Text("After \(rule.runtimeMinutes) min — \(rule.action.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingRule = rule
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Edit") { editingRule = rule }
                            Button("Duplicate") { autoStopRules.duplicate(rule) }
                            Divider()
                            Button("Delete", role: .destructive) { autoStopRules.remove(rule) }
                        }
                    }
                    .onDelete { autoStopRules.remove(at: $0) }
                }

                Section {
                    if autoStopRules.events.isEmpty {
                        Text("No auto-stop events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(autoStopRules.events.prefix(50)) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.processName).fontWeight(.medium)
                                    Spacer()
                                    Text(event.outcome.label)
                                        .foregroundStyle(event.outcome == .failed ? .red : .secondary)
                                }
                                Text("\(event.timestamp.formatted(date: .abbreviated, time: .standard)) · PID \(event.pid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Events")
                        Spacer()
                        if !autoStopRules.events.isEmpty {
                            Button("Clear") { autoStopRules.clearEvents() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Rule").font(.headline)
                TextFieldRow(label: "Process name", text: $newRuleName)
                Stepper(value: $newRuleMinutes, in: 1...240, step: 1) {
                    HStack {
                        Text("Runtime minutes")
                        Spacer()
                        Text("\(newRuleMinutes)").monospacedDigit()
                    }
                }
                Picker("Action", selection: $newRuleAction) {
                    ForEach(AutoStopRule.Action.allCases) { Text($0.label).tag($0) }
                }
                Button("Add Rule") {
                    if autoStopRules.add(AutoStopRule(
                        processName: newRuleName,
                        runtimeMinutes: newRuleMinutes,
                        action: newRuleAction
                    )) {
                        newRuleName = ""
                        newRuleMinutes = 5
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = autoStopRules.validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let error = autoStopRules.engineError {
                    Text("Auto-stop observation unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private var hotkeyTab: some View {
        HotkeySettingsView()
    }

    private func prepareNewPreset() {
        editingPresetID = nil
        newDisplayName = ""
        newMainProcess = ""
        newHelpers = ""
        newProtected = ""
        newAppPath = "/Applications/"
        newAgentLabels = ""
        newAgentPlistPaths = ""
        newDaemonLabels = ""
        newDaemonPlistPaths = ""
        newDaemonProcessNames = ""
        newDaemonPorts = ""
        presetValidationError = nil
        showPresetEditor = true
    }

    private func prepareToEdit(_ preset: WatchedAppPreset) {
        editingPresetID = preset.id
        newDisplayName = preset.displayName
        newMainProcess = preset.mainProcessName
        newHelpers = preset.helperProcessNames.joined(separator: ", ")
        newProtected = preset.protectedProcessNames.joined(separator: ", ")
        newAppPath = preset.appPath
        newAgentLabels = preset.userLaunchAgentJobs.map(\.label).joined(separator: ", ")
        newAgentPlistPaths = preset.userLaunchAgentJobs.map(\.plistPath).joined(separator: ", ")
        newDaemonLabels = preset.systemLaunchDaemonJobs.map(\.label).joined(separator: ", ")
        newDaemonPlistPaths = preset.systemLaunchDaemonJobs.map(\.plistPath).joined(separator: ", ")
        newDaemonProcessNames = preset.systemLaunchDaemonJobs.map(\.processName).joined(separator: ", ")
        newDaemonPorts = preset.systemLaunchDaemonJobs
            .map { $0.servicePort.map(String.init) ?? "" }
            .joined(separator: ",")
        presetValidationError = nil
        showPresetEditor = true
    }

    private func savePresetEditor() {
        let agents = PresetInputParser.parseUserLaunchAgentJobs(
            labels: newAgentLabels,
            paths: newAgentPlistPaths
        )
        let daemons = PresetInputParser.parseSystemLaunchDaemonJobs(
            labels: newDaemonLabels,
            paths: newDaemonPlistPaths,
            processNames: newDaemonProcessNames,
            ports: newDaemonPorts
        )
        let mappingErrors = agents.errors + daemons.errors
        guard mappingErrors.isEmpty else {
            presetValidationError = mappingErrors.joined(separator: " ")
            return
        }

        let existing = editingPresetID.flatMap { id in
            watchedApps.presets.first(where: { $0.id == id })
        }
        let preset = WatchedAppPreset(
            id: existing?.id ?? UUID(),
            displayName: newDisplayName.isEmpty ? newMainProcess : newDisplayName,
            mainProcessName: newMainProcess,
            helperProcessNames: PresetInputParser.list(from: newHelpers),
            protectedProcessNames: PresetInputParser.list(from: newProtected),
            appPath: newAppPath,
            userLaunchAgentJobs: agents.value,
            systemLaunchDaemonJobs: daemons.value,
            notificationsEnabled: existing?.notificationsEnabled ?? true
        )
        let saved = existing == nil ? watchedApps.add(preset) : watchedApps.update(preset)
        guard saved else {
            presetValidationError = watchedApps.validationError
            return
        }
        presetValidationError = nil
        showPresetEditor = false
    }

    private func exportPresets() {
        guard let data = try? JSONEncoder().encode(watchedApps.presets) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TaskScope-presets.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func importPresets(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WatchedAppPreset].self, from: data) else {
            importError = "Could not read presets from file."
            return
        }
        let existingIds = Set(watchedApps.presets.map { $0.id })
        var rejected = 0
        for preset in decoded where !existingIds.contains(preset.id) {
            if !watchedApps.add(preset) {
                rejected += 1
            }
        }
        importError = rejected == 0
            ? nil
            : "\(rejected) imported preset\(rejected == 1 ? " was" : "s were") rejected by validation."
    }
}

private struct AutoStopRuleEditorSheet: View {
    @State private var draft: AutoStopRule
    let onSave: (AutoStopRule) -> Void
    let onCancel: () -> Void

    init(
        rule: AutoStopRule,
        onSave: @escaping (AutoStopRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Auto-Stop Rule")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Process name", text: $draft.processName)
                .textFieldStyle(.roundedBorder)

            Stepper(value: $draft.runtimeMinutes, in: 1...1440) {
                Text("Runtime: \(draft.runtimeMinutes) minute\(draft.runtimeMinutes == 1 ? "" : "s")")
            }

            Picker("Action", selection: $draft.action) {
                ForEach(AutoStopRule.Action.allCases) { action in
                    Text(action.label).tag(action)
                }
            }

            Toggle("Enabled", isOn: $draft.isEnabled)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct TextFieldRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).frame(width: 180, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct HotkeySettingsView: View {
    @ObservedObject private var hotkey = HotkeyManager.shared
    @State private var recording = false

    var body: some View {
        Form {
            Section("Global Hotkey") {
                Toggle("Enable global Show TaskScope hotkey", isOn: $hotkey.hotkeyEnabled)

                HStack {
                    Text("Current Hotkey")
                    Spacer()
                    Text(hotkey.displayString)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                Button(recording ? "Press a key combination…" : "Record New Hotkey") {
                    recording = true
                }
                .disabled(!hotkey.hotkeyEnabled)
                .buttonStyle(.bordered)

                if recording {
                    Text("Press the key combination you want to use. Esc to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(hotkey.registrationStatus.message)
                    .font(.caption)
                    .foregroundStyle(
                        hotkey.registrationStatus == .registered
                            ? Color.secondary
                            : Color.orange
                    )

                Text("Default: ⌘⇧T shows the TaskScope window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .background {
            RecordingListenerView(
                isRecording: $recording,
                onRecord: { keyCode, modifiers in
                    _ = hotkey.updateShortcut(keyCode: keyCode, modifiers: modifiers)
                    recording = false
                },
                onCancel: {
                    recording = false
                }
            )
        }
    }
}

private struct RecordingListenerView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt32, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            guard context.coordinator.localMonitor == nil else { return }

            context.coordinator.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var carbonMods: UInt32 = 0
                if mods.contains(.command) { carbonMods |= UInt32(cmdKey) }
                if mods.contains(.shift) { carbonMods |= UInt32(shiftKey) }
                if mods.contains(.option) { carbonMods |= UInt32(optionKey) }
                if mods.contains(.control) { carbonMods |= UInt32(controlKey) }
                if carbonMods == 0 { return event }
                onRecord(UInt32(event.keyCode), carbonMods)
                return nil
            }

            context.coordinator.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
                onCancel()
            }

            context.coordinator.resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                onCancel()
            }

        } else {
            context.coordinator.removeMonitors()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var localMonitor: Any?
        var globalMonitor: Any?
        var resignObserver: NSObjectProtocol?

        func removeMonitors() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitors()
    }
}
