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
                PresetActionButton(title: "Quit All Killable", systemImage: "stop.circle", role: .destructive, action: onQuitAll)
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
                        Text("Persistently disables its user launch agents. Open turns them back on.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!isKeepOffControlEnabled)
                .accessibilityHint(
                    "Does not disable a protected system launch daemon."
                )
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
        if isKeptOff && (snapshot.isMainRunning || snapshot.hasHelpers) { .orange }
        else if isKeptOff { .green }
        else if snapshot.isMainRunning { .red }
        else if snapshot.hasHelpers { .yellow }
        else if !snapshot.protectedRunning.isEmpty { .orange }
        else { .green }
    }

    private var label: String {
        if isKeptOff && (snapshot.isMainRunning || snapshot.hasHelpers) { "Enforcing" }
        else if isKeptOff { "Kept Off" }
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
