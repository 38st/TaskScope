import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore

    @State private var newDisplayName = ""
    @State private var newMainProcess = ""
    @State private var newHelpers = ""
    @State private var newProtected = ""
    @State private var newAppPath = "/Applications/"

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            watchedAppsTab.tabItem { Label("Watched Apps", systemImage: "shield.lefthalf.filled") }
        }
        .frame(width: 460, height: 460)
    }

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                HStack {
                    Text("Watched status interval")
                    Spacer()
                    Slider(value: $settings.refreshIntervalSeconds, in: 2...60, step: 1) {
                        Text("Interval")
                    }
                    Text("\(Int(settings.refreshIntervalSeconds))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                Toggle("Auto-refresh process list", isOn: $settings.autoRefreshProcessList)

                Stepper(value: $settings.processListLimit, in: 10...200, step: 10) {
                    HStack {
                        Text("Process list limit")
                        Spacer()
                        Text("\(settings.processListLimit)")
                            .monospacedDigit()
                    }
                }
            }

            Section("Highlight Thresholds") {
                HStack {
                    Text("CPU %")
                    Spacer()
                    Slider(value: $settings.cpuHighlightThreshold, in: 1...100, step: 1)
                    Text(String(format: "%.0f%%", settings.cpuHighlightThreshold))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Memory (MB)")
                    Spacer()
                    Slider(value: $settings.memHighlightThresholdMB, in: 100...8192, step: 64)
                    Text(String(format: "%.0f", settings.memHighlightThresholdMB))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
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
            List {
                ForEach(watchedApps.presets) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.displayName).fontWeight(.semibold)
                        Text("Main: \(preset.mainProcessName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Helpers: \(preset.helperProcessNames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Protected: \(preset.protectedProcessNames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("App path: \(preset.appPath)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
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
        }
        .padding(.vertical)
    }

    private func parseList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct TextFieldRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).frame(width: 160, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
