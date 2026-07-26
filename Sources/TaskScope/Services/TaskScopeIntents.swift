import AppIntents
import Foundation

@available(macOS 13.0, *)
struct StopWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Watched App"
    static let description = IntentDescription("Stop a watched app's main process by name.")

    @Parameter(title: "App Name")
    var appName: String

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.stopPreset(appName))
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

@available(macOS 13.0, *)
struct OpenWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Watched App"
    static let description = IntentDescription("Open a watched app by name.")

    @Parameter(title: "App Name")
    var appName: String

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.openPreset(appName))
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

@available(macOS 13.0, *)
struct RefreshTaskScopeIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh TaskScope"
    static let description = IntentDescription("Request TaskScope to refresh its watched status.")

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.refresh)
        return .result(dialog: IntentDialog(stringLiteral: result.message))
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
        AppShortcut(
            intent: OpenWatchedAppIntent(),
            phrases: ["Open watched app in \(.applicationName)"],
            shortTitle: "Open Watched App",
            systemImageName: "arrow.up.forward.app"
        )
    }
}
