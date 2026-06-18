import SwiftUI

struct FullProcessWindowView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var settings: SettingsStore

    @State private var pendingTermination: AppProcess?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            tableContent
            Divider()
            footer
        }
        .task {
            if !processManager.hasLoadedProcessList {
                await processManager.loadProcessList()
            }
        }
        .confirmationDialog(
            "Stop Process?",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }
            ),
            presenting: pendingTermination
        ) { process in
            Button("Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process) }
                pendingTermination = nil
            }
            Button("Force Stop \(process.name)", role: .destructive) {
                Task { await processManager.terminate(process, forceKill: true) }
                pendingTermination = nil
            }
            Button("Cancel", role: .cancel) { pendingTermination = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Processes")
                .font(.headline)
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            Picker("Sort", selection: Binding(
                get: { settings.sortKey },
                set: {
                    settings.sortKeyRaw = $0.rawValue
                    processManager.sortKey = $0
                }
            )) {
                ForEach(ProcessSortKey.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 110)

            Button {
                Task { await processManager.loadProcessList() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    private var tableContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID").frame(width: 70, alignment: .trailing)
                    Text("PPID").frame(width: 70, alignment: .trailing)
                    Text("CPU %").frame(width: 80, alignment: .trailing)
                    Text("MEM MB").frame(width: 90, alignment: .trailing)
                    Text("Net KB/s").frame(width: 110, alignment: .trailing)
                    Text("Disk KB/s").frame(width: 110, alignment: .trailing)
                    Text("").frame(width: 40)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                ForEach(filteredProcesses) { process in
                    HStack {
                        Text(process.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(process.pid)").frame(width: 70, alignment: .trailing)
                        Text("\(process.parentPID)").frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.1f", process.cpu)).frame(width: 80, alignment: .trailing)
                        Text(String(format: "%.0f", process.memoryMB)).frame(width: 90, alignment: .trailing)
                        Text(String(format: "%.1f / %.1f", process.netInKB, process.netOutKB)).frame(width: 110, alignment: .trailing)
                        Text(String(format: "%.1f / %.1f", process.diskReadKB, process.diskWriteKB)).frame(width: 110, alignment: .trailing)
                        Button(role: .destructive) {
                            pendingTermination = process
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(processManager.isCurrentProcess(process))
                        .frame(width: 40)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .background(
                        process.cpu >= settings.cpuHighlightThreshold
                            ? Color.orange.opacity(0.08)
                            : Color.clear
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(processManager.message).foregroundStyle(.secondary)
            Spacer()
            Text("\(filteredProcesses.count) processes")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(10)
    }

    private var filteredProcesses: [AppProcess] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return processManager.processes }
        return processManager.processes.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.command.localizedCaseInsensitiveContains(trimmed) ||
            String($0.pid).contains(trimmed)
        }
    }
}
