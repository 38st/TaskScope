import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.shared.register()
        URLSchemeHandler.shared.register()
    }
}

@main
struct TaskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager = ProcessManager()
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings = SettingsStore()
    @StateObject private var watchedApps = WatchedAppsStore()
    @StateObject private var savedSelections = SavedSelectionsStore()
    @StateObject private var autoStopRules = AutoStopRulesStore()

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "TaskScope.onboarded.v1")

    var body: some Scene {
        MenuBarExtra {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps,
                savedSelections: savedSelections,
                autoStopRules: autoStopRules
            )
            .frame(width: 480, height: 600)
            .environmentObject(settings)
            .environmentObject(watchedApps)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                settings: settings,
                watchedApps: watchedApps,
                autoStopRules: autoStopRules
            )
        }

        WindowGroup("About TaskScope") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("TaskScope Processes") {
            FullProcessWindowView(processManager: processManager, settings: settings)
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Onboarding") {
            OnboardingView(onComplete: {
                UserDefaults.standard.set(true, forKey: "TaskScope.onboarded.v1")
                showOnboarding = false
            })
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let runningCount = processManager.snapshots.reduce(0) { $0 + $1.runningNames.count }
        if runningCount > 0 {
            Label("TaskScope (\(runningCount))", systemImage: processManager.status.menuBarSystemImage)
                .labelStyle(.iconOnly)
                .overlay(alignment: .topTrailing) {
                    Text("\(runningCount)")
                        .font(.caption2)
                        .padding(2)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 8, y: -4)
                }
        } else {
            Label("TaskScope", systemImage: processManager.status.menuBarSystemImage)
                .labelStyle(.iconOnly)
        }
    }
}

