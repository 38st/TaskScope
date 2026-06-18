import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
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
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            Text("TaskScope")
                .font(.title2.bold())

            if let info = appInfo {
                Text("Version \(info.version) (\(info.build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Native macOS menu bar utility for monitoring running processes and stopping selected tasks.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Spacer()
        }
        .padding(32)
        .frame(width: 360, height: 280)
    }

    private var appInfo: (version: String, build: String)? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return (version, build)
    }
}
