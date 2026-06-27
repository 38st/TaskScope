import SwiftUI

struct ProcessRow: View {
    var process: AppProcess
    var isCurrentProcess: Bool
    var isSelected: Bool
    var isKeyboardSelected: Bool
    var isHighlightedCPU: Bool
    var isHighlightedMEM: Bool
    var showsExpandedMetrics: Bool = false
    var stopAction: () -> Void
    var toggleSelection: () -> Void
    var detailAction: () -> Void
    var forceStopAction: () -> Void
    var copyCommandAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .onTapGesture { toggleSelection() }

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

            if showsExpandedMetrics {
                Text("\(process.pid)")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Text("\(process.parentPID)")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Text(String(format: "%.1f / %.1f", process.netInKB, process.netOutKB))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)

                Text(String(format: "%.0f / %.0f", process.diskReadBlocks, process.diskWriteBlocks))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
            }

            Text(process.cpu, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(isHighlightedCPU ? .red : .primary)
                .frame(width: 54, alignment: .trailing)

            Text(process.memoryMB, format: .number.precision(.fractionLength(0)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(isHighlightedMEM ? .red : .primary)
                .frame(width: 64, alignment: .trailing)

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
            if isKeyboardSelected {
                Color.accentColor.opacity(0.12)
            } else if isHighlightedCPU || isHighlightedMEM {
                Color.orange.opacity(0.08)
            }
        }
    }
}
