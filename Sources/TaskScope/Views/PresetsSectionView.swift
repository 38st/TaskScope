import SwiftUI

struct PresetsSectionView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var confirmationState: ProcessConfirmationState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(processManager.snapshots) { snapshot in
                    PresetCard(
                        snapshot: snapshot,
                        onOpen: {
                            // Address the preset by identity, exactly as the quit
                            // buttons do. A display-name lookup also matches other
                            // presets' main process names, so a name collision could
                            // open a different preset than the card the user clicked.
                            let target = WatchedPresetCommandTarget(
                                id: snapshot.preset.id,
                                displayName: snapshot.preset.displayName
                            )
                            Task {
                                _ = await AppCommandBus.shared.submit(.openPresetEntity(target))
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
                        },
                        isKeptOff: snapshot.preset.id == WatchedAppPreset.globalProtectID
                            && settings.keepGlobalProtectOff,
                        isKeepOffControlEnabled: !settings.isReadOnlyAfterCorruption,
                        onKeepOffChanged: { keptOff in
                            if keptOff {
                                confirmationState.requestPresetAction(
                                    .keepOff,
                                    preset: snapshot.preset
                                )
                            } else {
                                // Turning the switch off means the VPN is usable
                                // again, including its service, not just enabled
                                // launchd overrides with no running service.
                                let target = WatchedPresetCommandTarget(
                                    id: snapshot.preset.id,
                                    displayName: snapshot.preset.displayName
                                )
                                Task { _ = await AppCommandBus.shared.submit(.openPresetEntity(target)) }
                            }
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
