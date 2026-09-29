import SwiftUI

struct TaskScopeFooterView: View {
    var isWorking: Bool
    var message: String
    var workingMessage: String? = nil
    var expandsMessage: Bool = false
    var summary: String?
    var quitAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(workingMessage ?? "Working...")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: expandsMessage)
            } else {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(expandsMessage ? nil : 1)
                    .fixedSize(horizontal: false, vertical: expandsMessage)
                    .help(message)
            }

            Spacer()

            if let summary {
                Text(summary)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Button {
                quitAction()
            } label: {
                Image(systemName: "power.circle")
            }
            .buttonStyle(.borderless)
            .help("Quit TaskScope")
            .accessibilityLabel("Quit TaskScope")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
