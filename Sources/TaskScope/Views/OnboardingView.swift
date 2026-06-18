import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.15, blue: 0.18),
                                Color(red: 0.18, green: 0.34, blue: 0.40)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 80, height: 80)

            Text("Welcome to TaskScope")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 14) {
                OnboardingRow(
                    icon: "scope",
                    title: "Watch Apps",
                    description: "TaskScope watches apps like GlobalProtect and notifies you when they start or stop."
                )
                OnboardingRow(
                    icon: "stop.circle",
                    title: "Stop Processes",
                    description: "Click any process in the popover to stop it. Use Force Stop for unresponsive processes."
                )
                OnboardingRow(
                    icon: "gearshape",
                    title: "Customize",
                    description: "Open Settings to add your own watched apps, adjust thresholds, and configure auto-stop rules."
                )
                OnboardingRow(
                    icon: "keyboard",
                    title: "Keyboard",
                    description: "Use ↑/↓ to navigate, Enter to stop, Cmd+A to select all, Cmd+Shift+A to clear."
                )
            }
            .padding(.horizontal, 8)

            Spacer()

            Button("Get Started") { onComplete() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 460, height: 560)
    }
}

private struct OnboardingRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
