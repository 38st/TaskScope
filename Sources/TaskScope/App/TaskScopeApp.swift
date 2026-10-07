import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var launchContext: TaskScopeLaunchContext
    @Published private(set) var windowPresentationAllowed: Bool
    /// Work that must happen before the process exits (restoring Activity
    /// Monitor state, flushing debounced settings writes).
    var willTerminate: (() -> Void)?
    /// Shows the main window. Installed once the runtime is bootstrapped.
    var showMainWindow: (() -> Void)?
    private let previouslyFrontmostApplication: NSRunningApplication?
    private var launchPhase = TaskScopeLaunchPhase.starting
    private var interactiveLaunchTask: Task<Void, Never>?
    private var automaticWindowSuppressionTask: Task<Void, Never>?

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
        // Bound every Accessibility request this process makes (GlobalProtect
        // disconnect, Activity Monitor handoff). The default is about six
        // seconds per call, which an unresponsive app multiplies per element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

        if launchContext != .startupVerification {
            HotkeyManager.shared.register()
        }
        if launchContext.suppressesAutomaticWindowPresentation {
            finalizeBackgroundLaunch()
            launchPhase = .running
        } else {
            scheduleInteractiveLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminate?()
    }

    /// Opening the running app again (Finder, Dock, Spotlight, Launchpad) is
    /// an explicit request for its window, including after a quiet login-item,
    /// automation, or URL launch whose windows were suppressed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchContext != .startupVerification else { return false }
        if let showMainWindow {
            showMainWindow()
            return false
        }
        permitWindowPresentation()
        return true
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, self.launchPhase == .starting else {
                return
            }

            self.launchPhase = .running
            self.interactiveLaunchTask = nil
            if NSApp.isActive {
                self.promoteInteractiveLaunch()
            } else {
                self.finalizeInactiveInteractiveLaunch()
            }
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
        startAutomaticWindowSuppression()
    }

    /// An interactive launch that is not active when the launch grace period
    /// ends keeps its interactive intent: the app stays a regular (Dock) app
    /// and its windows are presented on the next activation
    /// (`applicationDidBecomeActive` -> `promoteInteractiveLaunch`). Demoting
    /// to an accessory here hid a Dock-launched app whose activation was
    /// merely slow.
    private func finalizeInactiveInteractiveLaunch() {
        let presentation = TaskScopeInteractiveLaunchPresentation.resolve(isActive: false)
        precondition(!presentation.demotesToAccessory)
        // will-finish ran while the context was still pending and made the app
        // an accessory; an interactive launch keeps its Dock presence.
        NSApp.setActivationPolicy(.regular)
        hideAutomaticWindows()
        startAutomaticWindowSuppression()
    }

    private func startAutomaticWindowSuppression() {
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = Task { @MainActor [weak self] in
            // SwiftUI/AppKit restoration can order a default window after the
            // launch callback. Sweep briefly until an explicit presentation
            // request wins, so quiet launch contexts stay visually quiet.
            for _ in 0..<50 {
                guard let self,
                      !Task.isCancelled,
                      !self.windowPresentationAllowed else {
                    return
                }
                self.hideAutomaticWindows()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.automaticWindowSuppressionTask = nil
        }
    }

    private func promoteInteractiveLaunch() {
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = nil
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
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = nil
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
    @StateObject private var settings: SettingsStore
    @StateObject private var watchedApps: WatchedAppsStore
    @StateObject private var savedSelections = SavedSelectionsStore()
    @StateObject private var autoStopRules: AutoStopRulesStore
    @StateObject private var processHistory: ProcessHistory

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "TaskScope.onboarded.v1")
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false
    @State private var commandCoordinator: AppCommandCoordinator?
    @State private var notificationEnablement = NotificationEnablementCoordinator()
    /// One coordinator for the app's lifetime. Constructing it per view init
    /// created a new Accessibility runtime on every body evaluation, whose
    /// pending restoration then ran against a deallocated runtime.
    @State private var activityMonitor: ActivityMonitorCoordinator

    init() {
        let systemInventory = SystemProcessInventory()
        let sharedInventory = CoalescingProcessInventory(upstream: systemInventory)
        let settings = SettingsStore()
        let processManager = ProcessManager(
            processInventory: sharedInventory,
            verificationInventory: systemInventory
        )
        let watchedApps = WatchedAppsStore()
        let autoStopRules = AutoStopRulesStore(inventory: sharedInventory)
        let processHistory = ProcessHistory(inventory: sharedInventory)
        let coordinator = AppCommandCoordinator(
            processManager: processManager,
            presets: { watchedApps.presets },
            allowsCommands: {
                !ProcessInfo.processInfo.arguments.contains("--verify-startup")
            }
        )

        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.keptOffPresetsProvider = {
            settings.keepGlobalProtectOff
                ? watchedApps.presets.filter { $0.id == WatchedAppPreset.globalProtectID }
                : []
        }
        processManager.isPresetKeptOffProvider = { preset in
            preset.id == WatchedAppPreset.globalProtectID && settings.keepGlobalProtectOff
        }
        processManager.setPresetKeptOffHandler = { preset, keptOff in
            guard preset.id == WatchedAppPreset.globalProtectID else { return }
            settings.keepGlobalProtectOff = keptOff
        }
        AppCommandBus.shared.install { command in
            await coordinator.perform(command)
        }

        _processManager = StateObject(wrappedValue: processManager)
        _settings = StateObject(wrappedValue: settings)
        _watchedApps = StateObject(wrappedValue: watchedApps)
        _autoStopRules = StateObject(wrappedValue: autoStopRules)
        _processHistory = StateObject(wrappedValue: processHistory)
        _commandCoordinator = State(initialValue: coordinator)
        _activityMonitor = State(initialValue: ActivityMonitorCoordinator())
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
                        openFullWindow: { showTaskScopeWindow() },
                        activityMonitor: activityMonitor
                    )
                    .frame(minWidth: 760, minHeight: 560)
                    .environmentObject(settings)
                    .environmentObject(watchedApps)
                    .task {
                        await bootstrapRuntimeIfNeeded()
                        if appDelegate.windowPresentationAllowed {
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
                },
                activityMonitor: activityMonitor,
                menuBarConfirmation: AppModalMenuBarConfirmation()
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
                autoStopRules: autoStopRules,
                processManager: processManager
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
            // MenuBarExtra may size its native status item from rendered image
            // content, including a hidden badge. Keep this image and identity
            // constant; the popover already displays the live preset status.
            Label("TaskScope", systemImage: "waveform.path.ecg")
                .labelStyle(.iconOnly)
        }
        .task {
            await bootstrapRuntimeIfNeeded()
            if appDelegate.windowPresentationAllowed {
                openOnboardingIfNeeded()
            }
        }
        // Onboarding is gated on window presentation being allowed, not on the
        // launch context, so a background launch that is later activated by the
        // user is still offered onboarding on that first interactive activation.
        .onChange(of: appDelegate.windowPresentationAllowed) { _, allowed in
            if allowed {
                openOnboardingIfNeeded()
            }
        }
        .onChange(of: settings.refreshIntervalSeconds) { _, _ in
            configurePolling()
            processHistory.updateConsumerCadence(settings.refreshIntervalSeconds)
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
            let token = notificationEnablement.beginConfiguration(
                enabled: newValue,
                setDeliveryEnabled: { processManager.enableNotifications = $0 }
            )
            guard newValue else { return }

            Task {
                await NotificationService.shared.requestAuthorization()
                notificationEnablement.completeEnabledConfiguration(
                    token: token,
                    currentRunningNames: { eligibleNotificationNames() },
                    primeBaseline: {
                        NotificationService.shared.prime(initialRunningNames: $0)
                    },
                    setDeliveryEnabled: { processManager.enableNotifications = $0 }
                )
            }
        }
        .onChange(of: watchedApps.presets) { _, _ in
            TaskScopeShortcuts.refreshParameters(for: appDelegate.launchContext)
            // The refresh re-baselines on its own when the watched-name set changed,
            // so a newly watched app that was already running is not announced as
            // having just started.
            Task { await processManager.refreshWatchedStatus(showMessage: false) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task {
                await TaskScopeExternalStateRefresh.perform(
                    refreshLoginItem: { loginItemManager.refresh() },
                    refreshNotificationAuthorization: {
                        await NotificationService.shared.refreshAuthorizationStatus()
                    }
                )
            }
        }
    }

    private func bootstrapRuntimeIfNeeded() async {
        guard !didBootstrapRuntime,
              appDelegate.launchContext.performsRuntimeBootstrap else { return }
        didBootstrapRuntime = true

        loginItemManager.refresh()
        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.processListLimitProvider = { settings.processListLimit }
        processManager.sortKey = settings.sortKey
        processManager.enableNotifications = settings.enableNotifications
        HotkeyManager.shared.onShow = {
            showTaskScopeWindow()
        }
        appDelegate.showMainWindow = {
            showTaskScopeWindow()
        }
        appDelegate.willTerminate = {
            activityMonitor.restoreActivityMonitorState()
            settings.flushPendingWrites()
        }
        configurePolling()
        autoStopRules.start(
            cadence: 10,
            perform: AutoStopActionHandlerFactory.make(
                processManager: processManager,
                rules: autoStopRules
            )
        )
        await processManager.refreshWatchedStatus(showMessage: false)
        await processManager.enforceKeptOffPresets(force: true)

        if settings.enableNotifications {
            await NotificationService.shared.requestAuthorization()
            let running = eligibleNotificationNames()
            NotificationService.shared.prime(initialRunningNames: running)
        }

        TaskScopeShortcuts.refreshParameters(for: appDelegate.launchContext)
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
