import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    static let builtInDaemonGuidance = "Privileged system launch daemons are managed only by TaskScope’s built-in GlobalProtect preset; custom presets cannot configure them."

    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    @ObservedObject private var notificationService = NotificationService.shared

    @StateObject private var presetForm = WatchedPresetFormState()
    @State private var newRuleName = ""
    @State private var newRuleMinutes = 5
    @State private var newRuleAction: AutoStopRule.Action = .prompt
    @State private var editingRule: AutoStopRule?
    @State private var exportError: String?
    @State private var importError: String?
    @State private var presetValidationError: String?
    @State private var showImporter = false
    @State private var showPresetEditor = false

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
        GeneralSettingsTab(
            settings: settings,
            notificationService: notificationService
        )
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
                .disabled(watchedApps.isReadOnlyAfterCorruption)
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
                .disabled(watchedApps.isReadOnlyAfterCorruption)
            }
            .padding(.horizontal)

            Text(Self.builtInDaemonGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                            if preset.id == WatchedAppPreset.globalProtectID {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Edit") {
                                    prepareToEdit(preset)
                                }
                                .buttonStyle(.borderless)
                            }
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
                        if preset.id == WatchedAppPreset.globalProtectID {
                            Text("Built-in lifecycle: \(preset.systemLaunchDaemonJobs.count) protected system daemon\(preset.systemLaunchDaemonJobs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    watchedApps.move(from: from, to: to)
                }
                .onDelete { watchedApps.remove(at: $0) }
            }
            .disabled(watchedApps.isReadOnlyAfterCorruption)

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
            Text(presetForm.editingPresetID == nil ? "Add Watched App" : "Edit Watched App")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextFieldRow(label: "Display name", text: $presetForm.displayName)
                    TextFieldRow(label: "Main process name", text: $presetForm.mainProcess)
                    TextFieldRow(label: "Helpers (comma-separated)", text: $presetForm.helpers)
                    TextFieldRow(label: "Protected (comma-separated)", text: $presetForm.protectedProcesses)
                    TextFieldRow(label: "App bundle path", text: $presetForm.appPath)

                    Divider().padding(.vertical, 4)
                    Text("Launch Agents (optional)").font(.headline)
                    TextFieldRow(label: "Labels", text: $presetForm.agentLabels)
                    TextFieldRow(label: "Plist paths", text: $presetForm.agentPlistPaths)

                    Divider().padding(.vertical, 4)
                    Text(editingSystemLaunchDaemonJobs.isEmpty
                         ? "System Launch Daemons"
                         : "Built-in System Launch Daemons")
                        .font(.headline)
                    ForEach(editingSystemLaunchDaemonJobs.indices, id: \.self) { index in
                        let job = editingSystemLaunchDaemonJobs[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.label).fontWeight(.medium)
                            Text("\(job.processName) · \(job.plistPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(Self.builtInDaemonGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button(presetForm.editingPresetID == nil ? "Add Preset" : "Save Changes") {
                    savePresetEditor()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(presetForm.mainProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            if autoStopRules.isRulesReadOnlyAfterRecovery {
                Button("Reset Auto-Stop Rules After Backup", role: .destructive) {
                    autoStopRules.resetRulesAfterCorruption()
                }
                .padding(.horizontal)
            }
            if autoStopRules.isEventsReadOnlyAfterRecovery {
                Button("Reset Auto-Stop Events After Backup", role: .destructive) {
                    autoStopRules.resetEventsAfterCorruption()
                }
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
                .disabled(autoStopRules.isRulesReadOnlyAfterRecovery)

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
                                .disabled(autoStopRules.isEventsReadOnlyAfterRecovery)
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
            .disabled(autoStopRules.isRulesReadOnlyAfterRecovery)
        }
        .padding(.vertical)
    }

    private var hotkeyTab: some View {
        HotkeySettingsView()
    }

    private func prepareNewPreset() {
        presetForm.prepareForNewPreset()
        presetValidationError = nil
        showPresetEditor = true
    }

    private func prepareToEdit(_ preset: WatchedAppPreset) {
        presetForm.prepareForEditing(preset)
        presetValidationError = nil
        showPresetEditor = true
    }

    private var editingSystemLaunchDaemonJobs: [SystemLaunchDaemonJob] {
        guard presetForm.editingPresetID == WatchedAppPreset.globalProtectID else { return [] }
        return watchedApps.presets
            .first(where: { $0.id == WatchedAppPreset.globalProtectID })?
            .systemLaunchDaemonJobs ?? []
    }

    private func savePresetEditor() {
        let existing = presetForm.editingPresetID.flatMap { id in
            watchedApps.presets.first(where: { $0.id == id })
        }
        let preset: WatchedAppPreset
        switch presetForm.makePreset(existing: existing) {
        case .success(let value):
            preset = value
        case .failure(let error):
            presetValidationError = error.message
            return
        }
        let saved = existing == nil ? watchedApps.add(preset) : watchedApps.update(preset)
        guard saved else {
            presetValidationError = watchedApps.validationError
            return
        }
        presetValidationError = nil
        showPresetEditor = false
    }

    private func exportPresets() {
        // In corrupt mode the in-memory list is the empty array we fell back to, not
        // the user's presets. Exporting it would write a valid-looking but empty
        // backup — precisely when the banner is telling them to back up first.
        guard watchedApps.canExportPresets else {
            exportError = "Preset data is unreadable, so there is nothing to export. "
                + "Recover the backup noted above before resetting."
            return
        }
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
        let result = watchedApps.importPresets(decoded)
        importError = result.rejectedCount == 0
            ? nil
            : "\(result.rejectedCount) imported preset\(result.rejectedCount == 1 ? " was" : "s were") rejected by validation."
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
