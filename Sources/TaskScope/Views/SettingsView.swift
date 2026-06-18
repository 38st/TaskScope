import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore

    @State private var newDisplayName = ""
    @State private var newMainProcess = ""
    @State private var newHelpers = ""
    @State private var newProtected = ""
    @State private var newAppPath = "/Applications/"
    @State private var newRuleName = ""
    @State private var newRuleMinutes = 5
    @State private var newRuleAction: AutoStopRule.Action = .prompt
    @State private var exportError: String?
    @State private var importError: String?
    @State private var showImporter = false

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

            List {
                ForEach(watchedApps.presets) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(preset.displayName).fontWeight(.semibold)
                            Spacer()
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Preset").font(.headline)
                TextFieldRow(label: "Display name", text: $newDisplayName)
                TextFieldRow(label: "Main process name", text: $newMainProcess)
                TextFieldRow(label: "Helpers (comma-separated)", text: $newHelpers)
                TextFieldRow(label: "Protected (comma-separated)", text: $newProtected)
                TextFieldRow(label: "App path", text: $newAppPath)

                Button("Add Preset") {
                    let preset = WatchedAppPreset(
                        displayName: newDisplayName.isEmpty ? newMainProcess : newDisplayName,
                        mainProcessName: newMainProcess,
                        helperProcessNames: parseList(newHelpers),
                        protectedProcessNames: parseList(newProtected),
                        appPath: newAppPath
                    )
                    watchedApps.add(preset)
                    newDisplayName = ""
                    newMainProcess = ""
                    newHelpers = ""
                    newProtected = ""
                    newAppPath = "/Applications/"
                }
                .buttonStyle(.borderedProminent)
                .disabled(newMainProcess.isEmpty)
            }
            .padding(.horizontal)

            if let err = importError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private var autoStopTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(autoStopRules.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.processName).fontWeight(.medium)
                            Text("After \(rule.runtimeMinutes) min — \(rule.action.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { autoStopRules.remove(at: $0) }
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
                    autoStopRules.add(AutoStopRule(processName: newRuleName, runtimeMinutes: newRuleMinutes, action: newRuleAction))
                    newRuleName = ""
                    newRuleMinutes = 5
                }
                .buttonStyle(.borderedProminent)
                .disabled(newRuleName.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private var hotkeyTab: some View {
        let hotkey = HotkeyManager.shared
        return Form {
            Section("Global Hotkey") {
                Toggle("Enable global toggle hotkey", isOn: Binding(
                    get: { hotkey.hotkeyEnabled },
                    set: { newValue in
                        hotkey.hotkeyEnabled = newValue
                    }
                ))
                LabeledContent("Current Hotkey", value: hotkey.displayString)
                Text("Default: ⌘⇧T toggles the TaskScope popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func parseList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        for preset in decoded {
            watchedApps.add(preset)
        }
        importError = nil
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
