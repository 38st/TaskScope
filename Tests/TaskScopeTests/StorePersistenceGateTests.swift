import XCTest
@testable import TaskScope

/// P11 — `AutoStopRulesStore` and `SavedSelectionsStore` back up an unreadable payload but
/// have no `allowsPersistence` equivalent, so the very next write lands on the *primary* key
/// and the corrupt-but-recoverable bytes are gone. For the auto-stop event log the write is
/// fully automatic: `TaskScopeApp` starts the engine at launch and `record(...)` calls
/// `saveEvents()` on the first rule outcome.
@MainActor
final class P11UnguardedWritebackTests: XCTestCase {
    private let suiteName = "TaskScope.P11UnguardedWritebackTests"
    private let rulesKey = "auto-stop-rules-p11-tests"
    private let eventsKey = "auto-stop-events-p11-tests"
    private let selectionsKey = "saved-selections-p11-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Recovery

    /// The write gate is only safe if the user can lift it. Without an explicit
    /// reset they would be locked out of editing rules for good.
    func testExplicitResetRestoresRuleWritingAfterCorruption() throws {
        defaults.set(Data([0xFE, 0x03]), forKey: rulesKey)
        let store = makeRulesStore(inventory: P11StubInventory(processes: []))
        XCTAssertTrue(store.hasUnreadableData, "precondition: writing is disabled")
        XCTAssertTrue(store.rules.isEmpty)

        store.resetAfterCorruption()
        XCTAssertFalse(store.hasUnreadableData)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent))

        let reloaded = makeRulesStore(inventory: P11StubInventory(processes: []))
        XCTAssertEqual(reloaded.rules.map(\.processName), ["Example"])
    }

    func testExplicitResetRestoresSelectionSavingAfterCorruption() {
        defaults.set(Data([0xFE, 0x04]), forKey: selectionsKey)
        let store = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertTrue(store.isReadOnlyAfterCorruption, "precondition: saving is disabled")

        store.resetAfterCorruption()
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.save(name: "Editors", processes: [appProcess(pid: 10, elapsed: "00:10")]))

        let reloaded = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertEqual(reloaded.selections.map(\.name), ["Editors"])
    }

    // MARK: - AutoStopRulesStore

    /// Zero user interaction: a rule the user created in a previous session, an unreadable
    /// event log, and one engine tick (`evaluateNow()` is exactly what the launch-time loop in
    /// TaskScopeApp calls every 10s).
    func testUnreadableEventLogSurvivesAnAutomaticEngineTick() async throws {
        let corruptEvents = Data([0xFE, 0x02])
        defaults.set(
            try JSONEncoder().encode([AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent)]),
            forKey: rulesKey
        )
        defaults.set(corruptEvents, forKey: eventsKey)

        let store = makeRulesStore(inventory: P11StubInventory(processes: [appProcess(pid: 42, elapsed: "10:00")]))
        XCTAssertTrue(store.events.isEmpty, "precondition: events failed to decode")
        XCTAssertEqual(defaults.data(forKey: "\(eventsKey).corruptBackup"), corruptEvents, "precondition: backup taken")

        await store.evaluateNow()
        XCTAssertEqual(store.events.count, 1, "sanity: the engine recorded an outcome")

        XCTAssertEqual(
            defaults.data(forKey: eventsKey),
            corruptEvents,
            """
            The engine overwrote \(eventsKey) with its own one-element array without any user \
            action. WatchedAppsStore refuses to write after a decode failure (allowsPersistence); \
            AutoStopRulesStore.saveEvents() has no such gate.
            """
        )
    }

    /// The rules key has the same hole; it just needs one UI action instead of a timer tick.
    /// Compare WatchedAppsStoreTests.testCorruptPayloadIsBackedUpAndCannotBeOverwrittenByMutation.
    func testUnreadableRulePayloadSurvivesAddingANewRule() {
        let corruptRules = Data([0xFF, 0x01])
        defaults.set(corruptRules, forKey: rulesKey)
        let store = makeRulesStore()
        XCTAssertTrue(store.rules.isEmpty, "precondition: rules failed to decode")

        _ = store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt))

        XCTAssertEqual(
            defaults.data(forKey: rulesKey),
            corruptRules,
            "saveRules() wrote over the unreadable payload at its primary key."
        )
    }

    /// The single backup slot is reused, so a second decode failure destroys the first backup
    /// and nothing in the UI can restore either one.
    func testFirstCorruptBackupIsNotClobberedByASecondCorruptRead() {
        let firstCorrupt = Data([0xAA, 0x01])
        let secondCorrupt = Data([0xBB, 0x02])

        defaults.set(firstCorrupt, forKey: eventsKey)
        _ = makeRulesStore()
        XCTAssertEqual(defaults.data(forKey: "\(eventsKey).corruptBackup"), firstCorrupt)

        defaults.set(secondCorrupt, forKey: eventsKey)
        _ = makeRulesStore()

        XCTAssertEqual(
            hex(defaults.data(forKey: "\(eventsKey).corruptBackup")),
            hex(firstCorrupt),
            "loadRecovering(_:userDefaults:key:) reuses one backup key, so the older backup is lost."
        )
    }

    // MARK: - SavedSelectionsStore

    func testUnreadableSelectionPayloadSurvivesSavingANewSelection() {
        let corrupt = Data([0xFF, 0x01])
        defaults.set(corrupt, forKey: selectionsKey)
        let store = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertTrue(store.selections.isEmpty, "precondition: selections failed to decode")
        XCTAssertNotNil(store.recoveryMessage, "precondition: recovery message surfaced")

        // The save must be refused rather than accepted-and-dropped, so the caller
        // can tell the user instead of reporting a save that cannot reach disk.
        let saved = store.save(name: "Editors", processes: [appProcess(pid: 10, elapsed: "00:10")])
        XCTAssertFalse(saved, "save must report failure while the payload is unreadable")
        XCTAssertNotNil(store.validationError)

        XCTAssertEqual(
            defaults.data(forKey: selectionsKey),
            corrupt,
            """
            The `didSet { saveToDefaults() }` observer wrote a one-element array over the \
            unreadable payload at \(selectionsKey); the only copy left is \
            \(selectionsKey).corruptBackup, which no UI reads.
            """
        )
    }

    // MARK: - Synthesized decoder brittleness

    /// `AutoStopEvent` is persisted with a purely synthesized decoder. Swift's synthesized
    /// `init(from:)` ignores property default values, so a payload missing any non-optional
    /// key fails outright — which is exactly what every previously written events payload
    /// looks like the moment a field is added. `AutoStopRule`, `WatchedAppPreset`,
    /// `SavedSelection` and `CodableSettings` all hand-write `init(from:)` with
    /// `decodeIfPresent` and tolerate it.
    func testPersistedEventDecoderHonoursPropertyDefaultsLikeEveryOtherPersistedType() throws {
        let ruleMissingDefaultedFields = Data(#"[{"processName":"Example","runtimeMinutes":5,"action":"silent"}]"#.utf8)
        let eventMissingDefaultedField = Data(
            #"[{"timestamp":0,"processName":"Example","pid":42,"ruleID":"00000000-0000-0000-0000-000000000001","outcome":"logged","detail":"x"}]"#.utf8
        )

        // Control: the hand-written decoder tolerates missing `id` and `isEnabled`.
        XCTAssertNoThrow(try JSONDecoder().decode([AutoStopRule].self, from: ruleMissingDefaultedFields))

        // AutoStopEvent.id is declared `var id: UUID = UUID()` — the default is ignored.
        do {
            _ = try JSONDecoder().decode([AutoStopEvent].self, from: eventMissingDefaultedField)
        } catch {
            XCTFail(
                """
                AutoStopEvent's synthesized decoder ignored `var id: UUID = UUID()` and threw: \(error). \
                Any field added to AutoStopEvent therefore makes every already-persisted \
                TaskScope.autoStopEvents.v1 payload undecodable — which routes straight into the \
                unguarded corrupt path proven above and overwrites the audit log.
                """
            )
        }
    }

    // MARK: - Helpers

    private func makeRulesStore(
        inventory: any ProcessInventoryProviding = P11StubInventory(processes: [])
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: rulesKey,
            eventsKey: eventsKey,
            inventory: inventory,
            eventLimit: 200,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func hex(_ data: Data?) -> String {
        data.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "<nil>"
    }

    private func appProcess(
        pid: Int32,
        command: String = "/Applications/Example.app/Example",
        elapsed: String
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 0,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: elapsed,
            startTime: "start-\(pid)",
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }
}

private struct P11StubInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
