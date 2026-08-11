import SwiftUI

struct ProcessRow: View {
    var process: AppProcess
    var isCurrentProcess: Bool
    var isSelected: Bool
    var isKeyboardSelected: Bool
    var isHighlightedCPU: Bool
    var isHighlightedMEM: Bool
    var showsExpandedMetrics: Bool = false
    var leadingInset: CGFloat = 0
    var stopAction: () -> Void
    var toggleSelection: () -> Void
    var detailAction: () -> Void
    var forceStopAction: () -> Void
    var copyCommandAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentProcess)
            .help(isCurrentProcess ? "TaskScope cannot select its own process" : "Toggle Selection")
            .accessibilityLabel(
                isCurrentProcess
                    ? "TaskScope cannot be selected"
                    : (isSelected ? "Remove \(process.name) from selection" : "Add \(process.name) to selection")
            )
            .accessibilityHint(
                isCurrentProcess
                    ? "TaskScope protects its own process"
                    : "Changes the batch action selection"
            )

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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(process.name), PID \(process.pid)")
            .accessibilityValue(accessibilitySummary)
            .accessibilityHint("Command: \(process.displayCommand)")

            Spacer(minLength: 8)

            if showsExpandedMetrics {
                Text("\(process.pid)")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)

                Text("\(process.parentPID)")
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(metricPair(process.netInKB, process.netOutKB, decimals: 1))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(metricPair(process.diskReadBlocks, process.diskWriteBlocks, decimals: 0))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            Text(process.cpu, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(isHighlightedCPU ? .red : .primary)
                .frame(width: 54, alignment: .trailing)
                .accessibilityHidden(true)

            Text(process.memoryMB, format: .number.precision(.fractionLength(0)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(isHighlightedMEM ? .red : .primary)
                .frame(width: 64, alignment: .trailing)
                .accessibilityHidden(true)

            Button(role: .destructive) {
                stopAction()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentProcess)
            .help(isCurrentProcess ? "Use Quit TaskScope" : "Stop Process")
            .accessibilityLabel("Stop \(process.name)")
            .frame(width: 28)
        }
        .padding(.leading, 16 + leadingInset)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .background {
            if isKeyboardSelected {
                Color.accentColor.opacity(0.12)
            } else if isHighlightedCPU || isHighlightedMEM {
                Color.orange.opacity(0.08)
            }
        }
    }

    private func metricPair(_ first: Double?, _ second: Double?, decimals: Int) -> String {
        guard let first, let second else { return "—" }
        return String(format: "%.*f / %.*f", decimals, first, decimals, second)
    }

    private var accessibilitySummary: String {
        var values = ["CPU \(process.cpu.formatted(.number.precision(.fractionLength(1)))) percent"]
        values.append("memory \(process.memoryMB.formatted(.number.precision(.fractionLength(0)))) megabytes")
        if isHighlightedCPU { values.append("high CPU") }
        if isHighlightedMEM { values.append("high memory") }
        return values.joined(separator: ", ")
    }
}
