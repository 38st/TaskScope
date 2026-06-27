import SwiftUI

struct TaskScopeFooterView: View {
    var isWorking: Bool
    var message: String
    var summary: String?
    var quitAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Working...")
                    .foregroundStyle(.secondary)
            } else {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
