import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notificationService: NotificationService

    var body: some View {
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
            .disabled(settings.isReadOnlyAfterCorruption)

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
            .disabled(settings.isReadOnlyAfterCorruption)

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
            .disabled(settings.isReadOnlyAfterCorruption)

            if let recoveryMessage = settings.recoveryMessage {
                Section("Recovered Settings") {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Reset Settings After Backup", role: .destructive) {
                        settings.resetAfterCorruption()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
