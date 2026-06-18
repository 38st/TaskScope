import AppKit
import SwiftUI

enum TaskScopeSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case presets = "Presets"

    var id: String {
        rawValue
    }
}

struct TaskScopePopoverView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager

    @State private var selectedSection: TaskScopeSection = .processes
    @State private var searchText = ""
    @State private var pendingTermination: AppProcess?

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker

            Divider()

            Group {
                switch selectedSection {
                case .processes:
                    processList
                case .presets:
                    presetsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(.regularMaterial)
        .task {
            loginItemManager.refresh()
            await processManager.refreshWatchedStatus(showMessage: false)
        }
        .confirmationDialog(
            "Stop Process?",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingTermination = nil
                    }
                }
            ),
            presenting: pendingTermination
        ) { process in
            Button("Stop \(process.name)", role: .destructive) {
                Task {
                    await processManager.terminate(process)
                }
                pendingTermination = nil
            }

            Button("Cancel", role: .cancel) {
                pendingTermination = nil
            }
        } message: { process in
            Text("Send a normal quit signal to PID \(process.pid).")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(headerGradient)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("TaskScope")
                    .font(.headline)

                Text(processManager.status.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusPill

            Button {
                refreshVisibleSection()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $selectedSection) {
            ForEach(TaskScopeSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var processList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search processes", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack {
                Text(processCountTitle)
                Spacer()
                Text("CPU")
                    .frame(width: 54, alignment: .trailing)
                Text("MEM")
                    .frame(width: 54, alignment: .trailing)
                Text("")
                    .frame(width: 28)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

            if processManager.hasLoadedProcessList {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProcesses) { process in
                            ProcessRow(
                                process: process,
                                isCurrentProcess: processManager.isCurrentProcess(process),
                                stopAction: {
                                    pendingTermination = process
                                }
                            )
                        }
                    }
                }
            } else {
                LightweightEmptyState {
                    Task {
                        await processManager.loadProcessList()
                    }
                }
            }
        }
    }

    private var presetsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presetHeader

                VStack(spacing: 8) {
                    PresetActionButton(
                        title: "Open GlobalProtect",
                        systemImage: "arrow.up.forward.app",
                        role: nil,
                        action: {
                            Task {
                                await processManager.openGlobalProtect()
                            }
                        }
                    )

                    PresetActionButton(
                        title: "Quit App",
                        systemImage: "power",
                        role: .destructive,
                        action: {
                            Task {
                                await processManager.quitGlobalProtect()
                            }
                        }
                    )

                    PresetActionButton(
                        title: "Quit User Helper",
                        systemImage: "wrench.and.screwdriver",
                        role: .destructive,
                        action: {
                            Task {
                                await processManager.quitHelpers()
                            }
                        }
                    )

                    PresetActionButton(
                        title: "Quit App + User Helper",
                        systemImage: "stop.circle",
                        role: .destructive,
                        action: {
                            Task {
                                await processManager.quitAllWatched()
                            }
                        }
                    )
                }

                serviceHealthNotice

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

            }
            .padding(16)
        }
    }

    private var presetHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GlobalProtect", systemImage: "network.badge.shield.half.filled")
                    .font(.headline)

                Spacer()

                statusPill
            }

            Text(processManager.watchedProcesses.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var serviceHealthNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: serviceHealthSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(serviceHealthColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("GlobalProtect Service")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(serviceHealthText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if processManager.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Working...")
                    .foregroundStyle(.secondary)
            } else {
                Text(processManager.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power.circle")
            }
            .buttonStyle(.borderless)
            .help("Quit TaskScope")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(processManager.status.title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var filteredProcesses: [AppProcess] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSearch.isEmpty else {
            return processManager.processes
        }

        return processManager.processes.filter { process in
            process.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                process.command.localizedCaseInsensitiveContains(trimmedSearch) ||
                String(process.pid).contains(trimmedSearch)
        }
    }

    private var processCountTitle: String {
        if !processManager.hasLoadedProcessList {
            return "Not loaded"
        }

        let hasSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSearch ? "\(filteredProcesses.count) matches" : "Top \(filteredProcesses.count)"
    }

    private var statusColor: Color {
        switch processManager.status {
        case .idle:
            .green
        case .helpersOnly:
            .yellow
        case .watchedRunning:
            .red
        }
    }

    private var serviceHealthSymbol: String {
        processManager.watchedProcesses.panGPS ? "checkmark.shield" : "exclamationmark.triangle"
    }

    private var serviceHealthColor: Color {
        processManager.watchedProcesses.panGPS ? .green : .orange
    }

    private var serviceHealthText: String {
        if processManager.watchedProcesses.panGPS {
            return "PanGPS is running. TaskScope leaves the privileged service alone."
        }

        if processManager.watchedProcesses.globalProtect {
            return "GlobalProtect is open, but PanGPS is not running. Reboot or update GlobalProtect before connecting."
        }

        return "PanGPS is not running. TaskScope can open or quit the user app, but service repair belongs to GlobalProtect."
    }

    private var headerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.15, blue: 0.18),
                Color(red: 0.18, green: 0.34, blue: 0.40)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func refreshVisibleSection() {
        Task {
            switch selectedSection {
            case .processes:
                await processManager.loadProcessList()
            case .presets:
                await processManager.refreshWatchedStatus()
            }
        }
    }

}

private struct LightweightEmptyState: View {
    var loadAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "leaf")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Idle Until Needed")
                    .font(.headline)

                Text("Load a lightweight top-process snapshot when you need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            Button {
                loadAction()
            } label: {
                Label("Load Processes", systemImage: "bolt")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ProcessRow: View {
    var process: AppProcess
    var isCurrentProcess: Bool
    var stopAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: process.isWatched ? "scope" : "app.dashed")
                .foregroundStyle(process.isWatched ? .red : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text("\(process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(process.displayCommand)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(process.cpu, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .font(.caption)
                .frame(width: 54, alignment: .trailing)

            Text(process.memory, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .font(.caption)
                .frame(width: 54, alignment: .trailing)

            Button(role: .destructive) {
                stopAction()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentProcess)
            .help(isCurrentProcess ? "Use Quit TaskScope" : "Stop Process")
            .frame(width: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            if process.isWatched {
                Color.red.opacity(0.07)
            }
        }
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
