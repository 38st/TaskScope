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

    var body: some Scene {
        MenuBarExtra {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager
            )
            .frame(width: 440, height: 560)
        } label: {
            Label("TaskScope", systemImage: processManager.status.menuBarSystemImage)
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.window)
    }
}
