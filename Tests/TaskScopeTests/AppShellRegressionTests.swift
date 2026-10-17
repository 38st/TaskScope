import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class AppShellRegressionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.AppShell.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testDuplicateLaunchHandsOffBeforeRuntimeOrPreferences() {
        for context in [TaskScopeLaunchContext.interactive, .loginItem, .automation, .urlAutomation] {
            var events: [String] = []
            let session = TaskScopeLaunchSession(
                context: context,
                runtime: runtime(instances: [instance(pid: 42)]) {
                    events.append($0)
                },
                standardDefaults: {
                    events.append("preferences")
                    return self.defaults
                }
            )
            defer { session.cleanUp() }

            XCTAssertFalse(session.continueLaunching(), "A duplicate must not continue launching")
            XCTAssertFalse(session.allowsRuntime, "A duplicate must not start polling or accept commands")
            XCTAssertEqual(events, ["activate 42", "terminate"], "Handoff must not read shared preferences")
            XCTAssertFalse(session.continueLaunching())
            XCTAssertEqual(events, ["activate 42", "terminate"], "Handoff occurs only once")
        }
    }

    @MainActor
    func testLaunchIgnoresSelfOtherUsersAndOtherBundleIdentifiers() {
        let session = TaskScopeLaunchSession(
            context: .loginItem,
            runtime: runtime(instances: [
                instance(pid: 10),
                instance(pid: 42, uid: 502),
                instance(pid: 43, bundleIdentifier: "example.Other")
            ]) { _ in XCTFail("An unrelated process must not cause a handoff") },
            standardDefaults: { self.defaults }
        )
        defer { session.cleanUp() }
        XCTAssertTrue(session.continueLaunching())
        XCTAssertTrue(session.allowsRuntime)
        XCTAssertTrue(session.userDefaults === defaults)
    }

    @MainActor
    func testVerificationStoresAndOnboardingAreIsolatedAndCleanedUp() {
        defaults.set(true, forKey: "TaskScope.onboarded.v1")
        let existing = SettingsStore(userDefaults: defaults)
        existing.keepGlobalProtectOff = true
        for key in [WatchedAppsStore.defaultPersistenceKey, "TaskScope.autoStopRules.v1",
                    "TaskScope.autoStopEvents.v1", "TaskScope.savedSelections.v1"] {
            defaults.set(Data([0xFE, 0xED]), forKey: key)
        }
        let before = defaults.persistentDomain(forName: suiteName)!
        var standardReads = 0
        let session = TaskScopeLaunchSession(
            context: .startupVerification,
            runtime: runtime(instances: [instance(pid: 42)]) { _ in
                XCTFail("Verification must not hand off to the running app")
            },
            standardDefaults: {
                standardReads += 1
                return self.defaults
            }
        )
        defer { session.cleanUp() }
        let stores = TaskScopeLaunchStores(session: session, inventory: AppShellInventory())

        XCTAssertTrue(session.continueLaunching())
        XCTAssertFalse(session.allowsRuntime)
        XCTAssertEqual(standardReads, 0, "Verification must never request the real preferences")
        XCTAssertTrue(stores.showOnboarding, "Verification must not read the real onboarding flag")
        XCTAssertFalse(stores.settings.keepGlobalProtectOff)
        XCTAssertNil(stores.watchedApps.persistenceIssue)
        let isolatedDomains = session.userDefaults.volatileDomainNames.filter { $0.hasPrefix("TaskScope.Startup.") }
        XCTAssertEqual(isolatedDomains.count, 1)
        if let name = isolatedDomains.first {
            XCTAssertNil(session.userDefaults.persistentDomain(forName: name)?[WatchedAppsStore.defaultPersistenceKey])
            XCTAssertNotNil(session.userDefaults.data(forKey: WatchedAppsStore.defaultPersistenceKey))
        }
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)! as NSDictionary, before as NSDictionary)
        session.userDefaults.set(true, forKey: "TaskScope.onboarded.v1")
        session.cleanUp()
        XCTAssertNil(session.userDefaults.object(forKey: "TaskScope.onboarded.v1"))
    }

    @MainActor
    func testTerminationSignalRequestsGracefulTerminationAndCancelsRegistration() {
        var signalHandler: (@MainActor @Sendable () -> Void)?
        var installs = 0
        var terminations = 0
        var cancellations = 0
        let handler = TaskScopeTerminationHandler(
            install: { callback in
                installs += 1
                signalHandler = callback
                return { cancellations += 1 }
            },
            terminate: { terminations += 1 }
        )
        handler.start()
        handler.start()
        signalHandler?()
        XCTAssertEqual(installs, 1, "SIGTERM handling must be installed once")
        XCTAssertEqual(terminations, 1, "SIGTERM must request the normal application termination path")
        handler.stop()
        handler.stop()
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testEveryIntentQuerySignalsAutomationBeforeReturningEntities() async throws {
        let bus = AppCommandBus()
        var signals = 0
        var context = TaskScopeLaunchContext.pending
        bus.onIntentExecution = {
            signals += 1
            context = TaskScopeLaunchContext.receivingAutomation(current: context, phase: .starting)
        }
        let query = WatchedPresetEntityQuery(
            catalog: WatchedPresetCatalog(suiteName: suiteName),
            prepareForIntent: { bus.prepareForIntentExecution() }
        )
        _ = try await query.entities(for: [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(signals, 1)
        XCTAssertEqual(context, .urlAutomation, "A query-only cold launch must suppress presentation")
        _ = try await query.entities(matching: "Global")
        XCTAssertEqual(signals, 2)
        _ = try await query.entities(matching: " ")
        XCTAssertEqual(signals, 3)
        _ = try await query.suggestedEntities()
        XCTAssertEqual(signals, 4)
    }

    @MainActor
    func testLateIntentDemotesOnlyLaunchWithoutInteractiveSignal() async throws {
        let bus = AppCommandBus()
        var context = TaskScopeLaunchContext.interactive
        var hasInteractiveSignal = false
        bus.onIntentExecution = {
            context = TaskScopeLaunchContext.receivingAutomation(
                current: context, phase: .running, hasInteractiveSignal: hasInteractiveSignal
            )
        }
        bus.install { _ in .init(status: .completed, message: "refreshed") }
        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
        XCTAssertEqual(context, .urlAutomation, "A late intent must suppress a never-activated launch")

        context = .interactive
        hasInteractiveSignal = true
        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
        XCTAssertEqual(context, .interactive, "An app the user already opened must remain interactive")

        let query = WatchedPresetEntityQuery(
            catalog: WatchedPresetCatalog(suiteName: suiteName),
            prepareForIntent: { bus.prepareForIntentExecution() }
        )
        _ = try await query.suggestedEntities()
        XCTAssertEqual(context, .interactive)
        hasInteractiveSignal = false
        _ = try await query.suggestedEntities()
        XCTAssertEqual(context, .urlAutomation, "A late query alone must suppress a never-activated launch")
    }

    @MainActor
    func testCadenceChangesDoNotFloodVisibleHistory() async throws {
        let inventory = AppShellInventory()
        let history = ProcessHistory(inventory: inventory)
        history.beginSampling(cadence: 10)
        defer { history.endSampling() }
        for _ in 0..<200 where history.samples.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(history.samples.count, 1)
        for cadence in 11...15 {
            history.updateConsumerCadence(Double(cadence))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(history.samples.count, 1, "Changing cadence must reschedule without sampling")
        let loads = await inventory.loadCount
        XCTAssertEqual(loads, 1, "Cadence changes must not trigger extra inventory reads")
    }

    @MainActor
    func testCadenceRescheduleStillSamplesAndPausesWithoutConsumers() async throws {
        let inventory = AppShellInventory()
        let history = ProcessHistory(inventory: inventory)
        history.beginSampling(cadence: 60)
        defer { history.stop() }
        for _ in 0..<200 where history.samples.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        history.updateConsumerCadence(2)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(history.samples.count, 1, "Rescheduling must wait for the new cadence")
        for _ in 0..<600 where history.samples.count == 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(history.samples.count, 2, "Rescheduling must preserve future sampling")
        history.endSampling()
        history.updateConsumerCadence(2)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples.count, 2)
    }

    @MainActor
    func testAboutAndOnboardingUseTheApplicationIcon() throws {
        let icon = NSApplication.shared.applicationIconImage
        XCTAssertEqual(try AboutView().inspect().find(ViewType.Image.self).actualImage().nsImage(), icon)
        XCTAssertEqual(try OnboardingView(onComplete: {}).inspect().find(ViewType.Image.self).actualImage().nsImage(), icon)
    }

    @MainActor
    private func runtime(
        instances: [TaskScopeLaunchSession.Instance],
        event: @escaping (String) -> Void
    ) -> TaskScopeLaunchSession.Runtime {
        .init(
            bundleIdentifier: "example.TaskScope",
            processID: 10,
            userID: 501,
            runningInstances: { instances },
            activate: { event("activate \($0)") },
            terminate: { event("terminate") }
        )
    }

    @MainActor
    private func instance(
        pid: pid_t, uid: uid_t = 501, bundleIdentifier: String = "example.TaskScope"
    ) -> TaskScopeLaunchSession.Instance {
        .init(processID: pid, userID: uid, bundleIdentifier: bundleIdentifier)
    }
}

private actor AppShellInventory: ProcessInventoryProviding {
    private(set) var loadCount = 0

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        loadCount += 1
        return .success([])
    }
}
