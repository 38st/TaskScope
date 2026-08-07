import Darwin
import XCTest
@testable import TaskScope

/// Proof tests for the "inventory read failure is reported as a claim about the
/// target processes" defects (P5: `terminate`, P6: `batchTerminate`).
///
/// Both tests drive the same seam the existing `ProcessManagerTests` use: a fake
/// `ProcessInventoryProviding` whose first `load` succeeds (so a selection can be
/// built) and whose subsequent loads return `.failure` — i.e. `ps` exited
/// non-zero / hit the ShellCommandRunner timeout / `/bin/zsh` could not spawn.
@MainActor
final class ProcessInventoryFailureReportingTests: XCTestCase {
    // MARK: - P5

    func testTerminateWithUnreadableInventoryMustNotWipeSelectionOrClaimIdentityChanged() async {
        let target = process(pid: 40, name: "Target")
        let bystanderA = process(pid: 41, name: "BystanderA")
        let bystanderB = process(pid: 42, name: "BystanderB")
        let inventory = FakeProcessInventory(
            results: [
                .success([target, bystanderA, bystanderB]),
                .failure(.commandFailed("ps timed out"))
            ]
        )
        let signaler = FakeProcessSignaler(alivePids: [40, 41, 42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.loadProcessList()
        manager.select(manager.processes)
        XCTAssertEqual(manager.selectedPids, [40, 41, 42], "precondition: three processes selected")

        let result = await manager.terminate(target)

        // (a) Control — the read failed, so nothing may be signalled.
        XCTAssertTrue(
            signaler.sent.isEmpty,
            "no signal may be sent when the verification read failed"
        )

        // (b) The bystanders were never checked against anything, so their
        //     selection must survive an inventory read failure.
        XCTAssertEqual(
            manager.selectedPids.intersection([41, 42]),
            [41, 42],
            "an unreadable inventory must not wipe the selection of unrelated processes"
        )

        // (c) The user must not be told the target's identity changed: it was
        //     never compared against anything.
        XCTAssertNotEqual(
            manager.message,
            "Target is no longer the same running process.",
            "an unreadable inventory must not be reported as an identity change"
        )

        // (d) A failed read must raise the load-failure indicator.
        XCTAssertEqual(
            manager.processLoadError,
            "ps timed out",
            "an unreadable inventory must surface as processLoadError"
        )

        // (e) `.stale` means 'no longer the same running process'; returning it
        //     makes AutoStopRulesStore log .failed / "Automatic stop did not
        //     complete." for a stop that was never attempted.
        XCTAssertNotEqual(
            result,
            .stale,
            "a read failure must not be reported to callers as a stale target"
        )
    }

    // MARK: - P6

    func testBatchStopWithUnreadableInventoryMustNotReportEveryTargetAsNoLongerMatched() async {
        let first = process(pid: 40, name: "First")
        let second = process(pid: 41, name: "Second")
        let third = process(pid: 42, name: "Third")
        let inventory = FakeProcessInventory(
            results: [
                .success([first, second, third]),
                .failure(.commandFailed("ps timed out"))
            ]
        )
        let signaler = FakeProcessSignaler(alivePids: [40, 41, 42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.loadProcessList()
        manager.select(manager.processes)
        let targets = manager.selectionSnapshot()
        XCTAssertEqual(targets.count, 3, "precondition: three targets requested")

        await manager.batchTerminate(targets)

        // Controls — nothing signalled, and the summary line is honest.
        XCTAssertTrue(
            signaler.sent.isEmpty,
            "no signal may be sent when the pre-flight read failed"
        )
        XCTAssertEqual(
            manager.message,
            "Could not verify selected processes.",
            "summary line correctly reports the read failure"
        )

        // The per-target sheet must not assert that every still-running target
        // is already gone ("No longer matched") when nothing was checked.
        let labels = manager.batchActionReport?.targets.map(\.state.label) ?? []
        XCTAssertNotEqual(
            labels,
            ["No longer matched", "No longer matched", "No longer matched"],
            "an unreadable inventory must not be reported per-target as 'No longer matched'"
        )
        XCTAssertFalse(
            labels.contains("No longer matched"),
            "no target may be labelled 'No longer matched' when no target was checked"
        )
    }

    // MARK: - Fixtures

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        signaler: FakeProcessSignaler = FakeProcessSignaler(),
        lifecycle: any ProcessLifecycleServicing = NoopLifecycleService()
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        return manager
    }

    private func process(
        pid: Int32,
        startTime: String = "Sat Jul 26 11:20:17 2026",
        cpu: Double = 0,
        memory: Double = 0,
        name: String
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: cpu,
            memoryMB: memory,
            command: name,
            elapsedTime: "00:10",
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }
}

private final class NoopLifecycleService: ProcessLifecycleServicing, @unchecked Sendable {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> Bool { true }
}

private final class FakeProcessInventory: ProcessInventoryProviding, @unchecked Sendable {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private(set) var fetchExtendedRequests: [Bool] = []

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        fetchExtendedRequests.append(fetchExtendedStats)
        guard !results.isEmpty else {
            return .failure(.commandFailed("No fake result configured."))
        }
        if results.count == 1 {
            return results[0]
        }
        return results.removeFirst()
    }
}

private final class FakeProcessSignaler: ProcessSignaling {
    struct SentSignal: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private var alivePids: Set<Int32>
    private let exitsOnKill: Bool
    private let exitsOnTerminate: Bool
    private let rejectedPids: Set<Int32>
    private(set) var sent: [SentSignal] = []

    init(
        alivePids: Set<Int32> = [],
        exitsOnKill: Bool = false,
        exitsOnTerminate: Bool = false,
        rejectedPids: Set<Int32> = []
    ) {
        self.alivePids = alivePids
        self.exitsOnKill = exitsOnKill
        self.exitsOnTerminate = exitsOnTerminate
        self.rejectedPids = rejectedPids
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(SentSignal(signal: signal, pid: pid))
        if rejectedPids.contains(pid) {
            return false
        }
        if signal == SIGKILL, exitsOnKill {
            alivePids.remove(pid)
        }
        if signal == SIGTERM, exitsOnTerminate {
            alivePids.remove(pid)
        }
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        alivePids.contains(pid)
    }
}
