import Carbon.HIToolbox
import SwiftUI

struct HotkeySettingsView: View {
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
        NSView()
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

            context.coordinator.onCancel = onCancel
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        } else {
            context.coordinator.removeMonitors()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var localMonitor: Any?
        var globalMonitor: Any?
        var onCancel: (() -> Void)?

        @objc func applicationDidResignActive() {
            onCancel?()
        }

        func removeMonitors() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
            onCancel = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitors()
    }
}
