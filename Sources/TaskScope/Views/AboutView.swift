import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

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
        guard
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            !build.isEmpty
        else {
            return nil
        }
        return (version, build)
    }
}
