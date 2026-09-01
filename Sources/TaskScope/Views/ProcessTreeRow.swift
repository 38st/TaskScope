import SwiftUI

struct ProcessTreeRow<ContextMenuContent: View>: View {
    var node: ProcessTreeNode
    var depth: Int
    var settings: SettingsStore
    @ObservedObject var processManager: ProcessManager
    @Binding var keyboardSelectedPid: Int32?
    @Binding var pendingTermination: AppProcess?
    @Binding var detailProcess: AppProcess?
    @Binding var detailData: ProcessDetail?
    @Binding var detailFailed: Bool
    @Binding var expandedPids: Set<Int32>
    var showsExpandedMetrics: Bool
    var openInActivityMonitor: (Int32) -> Void
    @ViewBuilder var contextMenuContent: (AppProcess) -> ContextMenuContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                ProcessRow(
                    process: node.process,
                    isCurrentProcess: processManager.isCurrentProcess(node.process),
                    isSelected: processManager.selectedPids.contains(node.process.pid),
                    isKeyboardSelected: keyboardSelectedPid == node.process.pid,
                    isHighlightedCPU: node.process.cpu >= settings.cpuHighlightThreshold,
                    isHighlightedMEM: node.process.memoryMB >= settings.memHighlightThresholdMB,
                    showsExpandedMetrics: showsExpandedMetrics,
                    leadingInset: 20 + CGFloat(depth) * 16,
                    stopAction: { pendingTermination = node.process },
                    toggleSelection: { processManager.toggleSelection(node.process.pid) },
                    detailAction: {
                        detailData = nil
                        detailFailed = false
                        detailProcess = node.process
                    },
                    forceStopAction: {
                        pendingTermination = node.process
                    },
                    copyCommandAction: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            node.process.executablePath ?? node.process.command,
                            forType: .string
                        )
                    }
                )

                if !node.children.isEmpty {
                    Button {
                        if isExpanded {
                            expandedPids.remove(node.process.pid)
                        } else {
                            expandedPids.insert(node.process.pid)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
                    .layoutPriority(1)
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse children of \(node.process.name)"
                            : "Expand children of \(node.process.name)"
                    )
                    .padding(.leading, 4 + CGFloat(depth) * 16)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.clear)
                        .frame(width: 20, height: 28)
                        .padding(.leading, 4 + CGFloat(depth) * 16)
                }
            }
            .background(
                keyboardSelectedPid == node.process.pid
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                keyboardSelectedPid = node.process.pid
            }
            .id(node.process.pid)
            .contextMenu {
                contextMenuContent(node.process)
            }

            if isExpanded {
                ForEach(node.children) { child in
                    ProcessTreeRow(
                        node: child,
                        depth: depth + 1,
                        settings: settings,
                        processManager: processManager,
                        keyboardSelectedPid: $keyboardSelectedPid,
                        pendingTermination: $pendingTermination,
                        detailProcess: $detailProcess,
                        detailData: $detailData,
                        detailFailed: $detailFailed,
                        expandedPids: $expandedPids,
                        showsExpandedMetrics: showsExpandedMetrics,
                        openInActivityMonitor: openInActivityMonitor,
                        contextMenuContent: contextMenuContent
                    )
                }
            }
        }
    }

    private var isExpanded: Bool {
        expandedPids.contains(node.process.pid)
    }
}
