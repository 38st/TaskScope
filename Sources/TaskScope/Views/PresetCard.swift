import SwiftUI

struct PresetCard: View {
    var snapshot: WatchedAppSnapshot
    var onOpen: () -> Void
    var onQuitApp: () -> Void
    var onQuitHelpers: () -> Void
    var onQuitAll: () -> Void
    var isKeptOff: Bool
    var isKeepOffControlEnabled: Bool
    var onKeepOffChanged: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(snapshot.preset.displayName, systemImage: "network.badge.shield.half.filled")
                    .font(.headline)

                Spacer()

                statusBadge
            }

            Text(snapshot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(spacing: 8) {
                PresetActionButton(title: "Open", systemImage: "arrow.up.forward.app", role: nil, action: onOpen)
                PresetActionButton(title: "Quit App", systemImage: "power", role: .destructive, action: onQuitApp)
                PresetActionButton(title: "Quit Helpers", systemImage: "wrench.and.screwdriver", role: .destructive, action: onQuitHelpers)
                PresetActionButton(title: snapshot.preset.hasCanonicalGlobalProtectIdentity ? "Quit All" : "Quit All Killable", systemImage: "stop.circle", role: .destructive, action: onQuitAll)
            }

            if snapshot.preset.id == WatchedAppPreset.globalProtectID {
                Divider()
                Toggle(
                    isOn: Binding(
                        get: { isKeptOff },
                        set: onKeepOffChanged
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep GlobalProtect Off")
                            .fontWeight(.medium)
                        Text("Quit All disconnects and stops GlobalProtect. Open brings it back.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!isKeepOffControlEnabled)
                .accessibilityHint(
                    "Automatically disconnects and stops GlobalProtect. Keeps it off until you turn this off or choose Open."
                )
                if isKeptOff {
                    Button("Apply Keep Off…", role: .destructive) { onKeepOffChanged(true) }
                        .disabled(!isKeepOffControlEnabled)
                        .help("Retry stopping all GlobalProtect services with administrator approval.")
                }
                GlobalProtectCompatibilityButton(
                    keepOffRequested: isKeepOffControlEnabled ? isKeptOff : nil
                )
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        if isKeptOff && snapshot.hasAny { .orange }
        else if isKeptOff { .green }
        else if snapshot.isMainRunning { .red }
        else if snapshot.hasHelpers { .yellow }
        else if !snapshot.protectedRunning.isEmpty { .orange }
        else { .green }
    }

    private var label: String {
        if isKeptOff && !snapshot.protectedRunning.isEmpty { "Service running" }
        else if isKeptOff && snapshot.hasKeepOffTargets { "Enforcing" }
        else if isKeptOff && snapshot.hasAny { "Still running" }
        else if isKeptOff { "Off requested" }
        else if snapshot.isMainRunning { "Active" }
        else if snapshot.hasHelpers { "Helpers" }
        else if !snapshot.protectedRunning.isEmpty { "Services" }
        else { "Quiet" }
    }
}

private struct PresetActionButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
