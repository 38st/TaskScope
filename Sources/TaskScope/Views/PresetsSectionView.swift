import SwiftUI

struct PresetsSectionView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var confirmationState: ProcessConfirmationState

    var body: some View {
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
}
