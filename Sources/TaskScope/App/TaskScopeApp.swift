import AppKit
import SwiftUI

enum TaskScopeLaunchContext: Equatable {
    case interactive
    case background

    static func detect(arguments: [String], launchedAsLoginItem: Bool) -> TaskScopeLaunchContext {
        if launchedAsLoginItem
            || arguments.contains("--background")
            || arguments.contains("--automation") {
            return .background
        }
        return .interactive
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var launchContext: TaskScopeLaunchContext = .interactive

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginDescriptor = NSAppleEventManager.shared()
            .currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
        launchContext = TaskScopeLaunchContext.detect(
            arguments: ProcessInfo.processInfo.arguments,
            launchedAsLoginItem: loginDescriptor?.booleanValue ?? false
        )

        NSApp.setActivationPolicy(launchContext == .background ? .accessory : .regular)
        HotkeyManager.shared.register()
        URLSchemeHandler.shared.register()
        if launchContext == .interactive {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.async {
                NSApp.windows
                    .filter { $0.title == "TaskScope" || $0.title == "TaskScope Processes" }
                    .forEach { $0.orderOut(nil) }
            }
        }
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
    @StateObject private var processHistory = ProcessHistory()

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "TaskScope.onboarded.v1")
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false
    @State private var commandCoordinator: AppCommandCoordinator?

    var body: some Scene {
        WindowGroup("TaskScope", id: "processes") {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps,
                savedSelections: savedSelections,
                autoStopRules: autoStopRules,
                history: processHistory,
                presentationStyle: .expandedWindow,
                openFullWindow: nil
            )
            .frame(minWidth: 760, minHeight: 560)
            .environmentObject(settings)
            .environmentObject(watchedApps)
            .task {
                await bootstrapRuntimeIfNeeded()
                if appDelegate.launchContext == .interactive {
                    openOnboardingIfNeeded()
                }
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
                history: processHistory,
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
            // The badge represents active presets, not configured names or process instances.
            let runningCount = processManager.snapshots.filter(\.hasAny).count
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
            if appDelegate.launchContext == .interactive {
                openOnboardingIfNeeded()
            }
        }
        .onChange(of: settings.refreshIntervalSeconds) { _, _ in
            configurePolling()
            processHistory.start(cadence: settings.refreshIntervalSeconds)
        }
        .onChange(of: settings.autoRefreshProcessList) { _, _ in
            configurePolling()
        }
        .onChange(of: settings.sortKeyRaw) { _, _ in
            processManager.sortKey = settings.sortKey
        }
        .onChange(of: settings.processListLimit) { _, _ in
            processManager.applyCurrentDisplayLimit()
        }
        .onChange(of: settings.enableNotifications) { _, newValue in
            processManager.enableNotifications = newValue
            if newValue {
                Task {
                    await NotificationService.shared.requestAuthorization()
                    let running = eligibleNotificationNames()
                    NotificationService.shared.prime(initialRunningNames: running)
                }
            }
        }
        .onChange(of: watchedApps.presets) { _, _ in
            NotificationService.shared.prime(initialRunningNames: eligibleNotificationNames())
            Task { await processManager.refreshWatchedStatus(showMessage: false) }
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
        let coordinator = AppCommandCoordinator(
            processManager: processManager,
            presets: { watchedApps.presets }
        )
        commandCoordinator = coordinator
        AppCommandBus.shared.install { command in
            await coordinator.perform(command)
        }
        HotkeyManager.shared.onShow = {
            showTaskScopeWindow()
        }
        configurePolling()
        processHistory.start(cadence: settings.refreshIntervalSeconds)
        autoStopRules.start(cadence: 10) { process in
            await processManager.terminate(process)
        }
        await processManager.refreshWatchedStatus(showMessage: false)

        if settings.enableNotifications {
            await NotificationService.shared.requestAuthorization()
            let running = eligibleNotificationNames()
            NotificationService.shared.prime(initialRunningNames: running)
        }

    }

    private func configurePolling() {
        processManager.setPolling(
            interval: settings.refreshIntervalSeconds,
            includeProcessList: settings.autoRefreshProcessList
        )
    }

    private func eligibleNotificationNames() -> Set<String> {
        let enabledPresetIDs = Set(watchedApps.presets.filter(\.notificationsEnabled).map(\.id))
        return Set(
            processManager.snapshots
                .filter { enabledPresetIDs.contains($0.preset.id) }
                .flatMap(\.runningNames)
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
