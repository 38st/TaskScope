import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TaskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager = ProcessManager()
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings = SettingsStore()
    @StateObject private var watchedApps = WatchedAppsStore()

    var body: some Scene {
        MenuBarExtra {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps
            )
            .frame(width: 460, height: 580)
            .environmentObject(settings)
            .environmentObject(watchedApps)
        } label: {
            Label("TaskScope", systemImage: processManager.status.menuBarSystemImage)
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, watchedApps: watchedApps)
        }

        WindowGroup("About TaskScope") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
