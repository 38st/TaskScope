import AppIntents
import AppKit
import Foundation

@available(macOS 13.0, *)
struct StopWatchedAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Watched App"
    static var description = IntentDescription("Stop a watched app's main process by name.")

    @Parameter(title: "App Name")
    var appName: String

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        _ = await ShellCommandRunner.run("/usr/bin/pkill -x \(ShellCommandRunner.shellQuoted(appName)) 2>/dev/null || true")
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenWatchedAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Watched App"
    static var description = IntentDescription("Open a watched app by name.")

    @Parameter(title: "App Name")
    var appName: String

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        let path = "/Applications/\(appName).app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        return .result()
    }
}

@available(macOS 13.0, *)
struct RefreshTaskScopeIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh TaskScope"
    static var description = IntentDescription("Request TaskScope to refresh its watched status.")

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .taskScopeRefreshRequested, object: nil)
        }
        return .result()
    }
}

@available(macOS 13.0, *)
struct TaskScopeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshTaskScopeIntent(),
            phrases: ["Refresh \(.applicationName)"],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StopWatchedAppIntent(),
            phrases: ["Stop watched app in \(.applicationName)"],
            shortTitle: "Stop Watched App",
            systemImageName: "stop.circle"
        )
    }
}
