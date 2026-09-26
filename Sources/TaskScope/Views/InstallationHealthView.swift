import AppKit
import SwiftUI

struct InstallationHealthView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    let reviewPresets: () -> Void
    @StateObject private var controller = InstallationHealthController()
    @State private var isVisible = false

    private var input: InstallationHealthInput {
        .init(presets: watchedApps.presets, presetsReadable: !watchedApps.isReadOnlyAfterCorruption,
              notificationsEnabled: settings.isReadOnlyAfterCorruption ? nil : settings.enableNotifications)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Permission and Installation Health").font(.headline)
                Spacer()
                if controller.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh Health") { controller.refresh(input) }
                    .disabled(controller.isRefreshing)
            }
            Text("Read-only local checks. Recovery buttons open verified destinations for review. No permissions, login registration, files, or launch jobs are changed by these checks.")
                .font(.caption).foregroundStyle(.secondary)
            if let report = controller.report {
                Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .standard)). Results expire after one minute and when TaskScope becomes inactive.")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(report.displayedFindings(at: context.date, invalidated: controller.invalidated)) { finding in
                                InstallationHealthRow(finding: finding) { action in
                                    Task { @MainActor in
                                        if await controller.recover(action), action == .reviewPresets {
                                            reviewPresets()
                                        }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            } else {
                Text(controller.isRefreshing ? "Checking permissions and installation…" : "Refresh to check this installation.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let message = controller.actionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Health findings stay in memory and are not added to the Support JSON export.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { isVisible = true; controller.refresh(input) }
        .onDisappear { isVisible = false; controller.invalidate() }
        .onChange(of: input) { _, value in
            if isVisible { controller.refresh(value) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            controller.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isVisible { controller.refresh(input) }
        }
    }
}

struct InstallationHealthRow: View {
    let finding: InstallationHealthReport.Finding
    let recover: (InstallationHealthReport.Recovery) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(finding.category.rawValue).fontWeight(.semibold)
                Spacer()
                Text(finding.state.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(finding.state == .healthy ? Color.green : Color.secondary)
            }
            Text(finding.detail).font(.caption).textSelection(.enabled)
            if let action = finding.recovery {
                Button(action.rawValue) { recover(action) }
                    .accessibilityLabel("\(action.rawValue) for \(finding.category.rawValue)")
            }
        }
    }
}
