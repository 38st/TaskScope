import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        HotkeyManager.shared.register()
        URLSchemeHandler.shared.register()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TaskScopeApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager = ProcessManager()
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings = SettingsStore()
    @StateObject private var watchedApps = WatchedAppsStore()
    @StateObject private var savedSelections = SavedSelectionsStore()
    @StateObject private var autoStopRules = AutoStopRulesStore()

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "TaskScope.onboarded.v1")
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false

    var body: some Scene {
        WindowGroup("TaskScope", id: "processes") {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps,
                savedSelections: savedSelections,
                autoStopRules: autoStopRules,
                presentationStyle: .expandedWindow,
                openFullWindow: nil
            )
            .frame(minWidth: 760, minHeight: 560)
            .environmentObject(settings)
            .environmentObject(watchedApps)
            .task {
                await bootstrapRuntimeIfNeeded()
                openOnboardingIfNeeded()
            }
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps,
                savedSelections: savedSelections,
                autoStopRules: autoStopRules,
                presentationStyle: .menuBarCompact,
                openFullWindow: {
                    showTaskScopeWindow()
                }
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

        WindowGroup("Onboarding", id: "onboarding") {
            OnboardingView(onComplete: {
                completeOnboarding()
            })
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        Group {
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
        .task {
            await bootstrapRuntimeIfNeeded()
            openOnboardingIfNeeded()
        }
        .onChange(of: settings.refreshIntervalSeconds) { _, _ in
            configurePolling()
        }
        .onChange(of: settings.autoRefreshProcessList) { _, _ in
            configurePolling()
        }
        .onChange(of: settings.sortKeyRaw) { _, _ in
            processManager.sortKey = settings.sortKey
        }
        .onChange(of: settings.enableNotifications) { _, newValue in
            processManager.enableNotifications = newValue
            if newValue {
                Task {
                    await NotificationService.shared.requestAuthorization()
                    let running = Set(processManager.snapshots.flatMap { $0.runningNames })
                    NotificationService.shared.prime(initialRunningNames: running)
                }
            }
        }
        .onChange(of: watchedApps.presets) { _, _ in
            Task { await processManager.refreshWatchedStatusUnchecked(showMessage: false) }
        }
    }

    private func bootstrapRuntimeIfNeeded() async {
        guard !didBootstrapRuntime else { return }
        didBootstrapRuntime = true

        loginItemManager.refresh()
        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.processListLimitProvider = { settings.processListLimit }
        processManager.sortKey = settings.sortKey
        processManager.enableNotifications = settings.enableNotifications
        configurePolling()
        autoStopRules.start(cadence: 10) { process in
            await processManager.terminate(process)
        }
        await processManager.refreshWatchedStatus(showMessage: false)

        if settings.enableNotifications {
            await NotificationService.shared.requestAuthorization()
            let running = Set(processManager.snapshots.flatMap { $0.runningNames })
            NotificationService.shared.prime(initialRunningNames: running)
        }

        HotkeyManager.shared.onToggle = {
            showTaskScopeWindow()
        }
    }

    private func configurePolling() {
        processManager.setPolling(
            interval: settings.refreshIntervalSeconds,
            includeProcessList: settings.autoRefreshProcessList
        )
    }

    private func openOnboardingIfNeeded() {
        guard showOnboarding, !didRequestOnboarding else { return }
        didRequestOnboarding = true
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "TaskScope.onboarded.v1")
        showOnboarding = false
    }

    private func showTaskScopeWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        if let window = NSApp.windows.first(where: isTaskScopeMainWindow) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "processes")
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func isTaskScopeMainWindow(_ window: NSWindow) -> Bool {
        window.title == "TaskScope" || window.title == "TaskScope Processes"
    }
}
