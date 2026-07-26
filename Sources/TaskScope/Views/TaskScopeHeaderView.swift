import SwiftUI

struct TaskScopeHeaderView: View {
    var status: ProcessStatus
    var samples: [ProcessHistory.Sample]
    var samplingState: ProcessHistory.SamplingState
    var showsMetrics: Bool
    var showsOpenWindowButton: Bool
    var openFullWindow: (() -> Void)?
    var refreshAction: () -> Void

    var body: some View {
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

                Text(status.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsMetrics {
                HStack(spacing: 12) {
                    SparklineView(
                        samples: samples,
                        keyPath: \.observedProcessCPU,
                        color: .orange,
                        label: "PROC CPU %",
                        unit: "percent"
                    )
                        .frame(width: 70)
                    SparklineView(
                        samples: samples,
                        keyPath: \.observedProcessMemoryMB,
                        color: .blue,
                        label: "PROC RSS",
                        unit: "megabytes"
                    )
                        .frame(width: 70)
                }
                .help("Full observed process inventory · \(samplingState.label)")
            }

            Spacer()

            statusPill

            if showsOpenWindowButton, let openFullWindow {
                Button {
                    openFullWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open TaskScope Window")
            }

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                refreshAction()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(status.title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            .green
        case .helpersOnly:
            .yellow
        case .protectedOnly:
            .orange
        case .watchedRunning:
            .red
        }
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
}
