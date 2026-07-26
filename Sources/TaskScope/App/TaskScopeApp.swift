import AppKit
import SwiftUI

struct TaskScopeLaunchSignal: Equatable, Sendable {
    var arguments: [String]
    var launchedAsLoginItem: Bool
    var receivedOpenURL: Bool
}

enum TaskScopeLaunchContext: Equatable {
    case pending
    case interactive
    case loginItem
    case automation
    case urlAutomation

    static func detect(_ signal: TaskScopeLaunchSignal) -> TaskScopeLaunchContext {
        if signal.launchedAsLoginItem {
            return .loginItem
        }
        if signal.arguments.contains("--background")
            || signal.arguments.contains("--automation") {
            return .automation
        }
        if signal.receivedOpenURL {
            return .urlAutomation
        }
        return .interactive
    }

    static func resolve(
        current: TaskScopeLaunchContext,
        signal: TaskScopeLaunchSignal,
        finalizeInteractiveLaunch: Bool
    ) -> TaskScopeLaunchContext {
        let detected = detect(signal)
        if detected.suppressesAutomaticWindowPresentation {
            return detected
        }
        if current != .pending, current.suppressesAutomaticWindowPresentation {
            return current
        }
        return finalizeInteractiveLaunch ? .interactive : .pending
    }

    static func receivingURL(
        current: TaskScopeLaunchContext,
        phase: TaskScopeLaunchPhase
    ) -> TaskScopeLaunchContext {
        phase == .starting ? .urlAutomation : current
    }

    var suppressesAutomaticWindowPresentation: Bool {
        self != .interactive
    }

    var allowsExplicitCommands: Bool {
        true
    }
}

enum TaskScopeLaunchPhase: Equatable, Sendable {
    case starting
    case running
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var launchContext: TaskScopeLaunchContext
    @Published private(set) var windowPresentationAllowed: Bool
    private let previouslyFrontmostApplication: NSRunningApplication?
    private var launchPhase = TaskScopeLaunchPhase.starting
    private var interactiveLaunchTask: Task<Void, Never>?

    override init() {
        launchContext = .pending
        windowPresentationAllowed = false
        previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        resolveLaunchContext(finalizeInteractiveLaunch: false)
        URLSchemeHandler.shared.register { [weak self] _ in
            self?.prepareForIncomingURLCommand()
        }
        if launchContext.suppressesAutomaticWindowPresentation {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolveLaunchContext(finalizeInteractiveLaunch: true)

        HotkeyManager.shared.register()
        if launchContext.suppressesAutomaticWindowPresentation {
            finalizeBackgroundLaunch()
            launchPhase = .running
        } else {
            scheduleInteractiveLaunch()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard launchPhase == .running,
              launchContext == .interactive,
              !windowPresentationAllowed else {
            return
        }
        promoteInteractiveLaunch()
    }

    private func prepareForIncomingURLCommand() {
        let resolved = TaskScopeLaunchContext.receivingURL(
            current: launchContext,
            phase: launchPhase
        )
        guard resolved == .urlAutomation, resolved != launchContext else { return }

        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = nil
        launchContext = resolved
        finalizeBackgroundLaunch()
        launchPhase = .running
    }

    private func scheduleInteractiveLaunch() {
        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = Task { @MainActor [weak self] in
            // Launch Services delivers a cold-open URL after did-finish. Keep
            // restored/default windows suppressed until that launch event has
            // had a chance to reach the handler registered during will-finish.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, self.launchPhase == .starting else {
                return
            }

            self.launchPhase = .running
            self.interactiveLaunchTask = nil
            self.promoteInteractiveLaunch()
        }
    }

    private func resolveLaunchContext(finalizeInteractiveLaunch: Bool) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginDescriptor = event?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
        launchContext = TaskScopeLaunchContext.resolve(
            current: launchContext,
            signal: TaskScopeLaunchSignal(
                arguments: ProcessInfo.processInfo.arguments,
                launchedAsLoginItem: loginDescriptor?.booleanValue ?? false,
                receivedOpenURL: event?.eventClass == AEEventClass(kInternetEventClass)
                    && event?.eventID == AEEventID(kAEGetURL)
            ),
            finalizeInteractiveLaunch: finalizeInteractiveLaunch
        )
    }

    @objc
    private func windowDidBecomeVisible(_ notification: Notification) {
        guard !windowPresentationAllowed,
              let window = notification.object as? NSWindow,
              automaticWindowTitles.contains(window.title) else {
            return
        }
        window.orderOut(nil)
    }

    private func hideAutomaticWindows() {
        NSApp.windows
            .filter { automaticWindowTitles.contains($0.title) }
            .forEach { $0.orderOut(nil) }
    }

    private var automaticWindowTitles: Set<String> {
        ["TaskScope", "TaskScope Processes", "Onboarding", "About TaskScope"]
    }

    private func finalizeBackgroundLaunch() {
        NSApp.setActivationPolicy(.accessory)
        suppressAutomaticWindowPresentation()
    }

    private func promoteInteractiveLaunch() {
        launchContext = .interactive
        windowPresentationAllowed = true
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: {
                $0.title == "TaskScope" || $0.title == "TaskScope Processes"
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func suppressAutomaticWindowPresentation() {
        guard launchContext.suppressesAutomaticWindowPresentation,
              !windowPresentationAllowed else {
            return
        }
        hideAutomaticWindows()
        NSApp.deactivate()
        if let previous = previouslyFrontmostApplication,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.activate()
        }
    }

    func permitWindowPresentation() {
        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = nil
        launchPhase = .running
        windowPresentationAllowed = true
        NSApp.setActivationPolicy(.regular)
    }
}

@main
struct TaskScopeApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager: ProcessManager
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings = SettingsStore()
    @StateObject private var watchedApps: WatchedAppsStore
    @StateObject private var savedSelections = SavedSelectionsStore()
    @StateObject private var autoStopRules = AutoStopRulesStore()
    @StateObject private var processHistory = ProcessHistory()

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "TaskScope.onboarded.v1")
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false
    @State private var commandCoordinator: AppCommandCoordinator?

    init() {
        let processManager = ProcessManager()
        let watchedApps = WatchedAppsStore()
        let coordinator = AppCommandCoordinator(
            processManager: processManager,
            presets: { watchedApps.presets }
        )

        processManager.watchedAppsProvider = { watchedApps.presets }
        AppCommandBus.shared.install { command in
            await coordinator.perform(command)
        }

        _processManager = StateObject(wrappedValue: processManager)
        _watchedApps = StateObject(wrappedValue: watchedApps)
        _commandCoordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup("TaskScope", id: "processes") {
            Group {
                if appDelegate.windowPresentationAllowed {
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
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .onAppear {
                            appDelegate.suppressAutomaticWindowPresentation()
                        }
                }
            }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About TaskScope") {
                    showAboutWindow()
                }
            }
        }

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

        WindowGroup("About TaskScope", id: "about") {
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
        appDelegate.permitWindowPresentation()
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

    private func showAboutWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isTaskScopeMainWindow(_ window: NSWindow) -> Bool {
        window.title == "TaskScope" || window.title == "TaskScope Processes"
    }
}
