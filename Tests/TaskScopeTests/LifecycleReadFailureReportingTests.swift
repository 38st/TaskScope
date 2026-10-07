import XCTest
@testable import TaskScope

/// Regression coverage for P8 — a stop that signals nothing must not report
/// success when its fresh inventory gate is unavailable.
@MainActor
final class P8SilentStopReportsSuccessTests: XCTestCase {

    // MARK: - An unreadable process list fails closed

    func testStopWithUnreadableProcessListIsNotReportedAsSuccess() async {
        let harness = P8LifecycleRuntimeHarness(inventoryResult: .failure(.commandFailed("ps timed out")))
        let preset = presetWithoutLaunchAgentJobs()
        let manager = makeManager(
            inventory: P8QueuedInventory(results: [.failure(.commandFailed("ps timed out"))]),
            lifecycle: P8RealControllerLifecycleService(runtime: harness.runtime)
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.quitAllKillable(preset)

        // The preset has no launch-agent jobs, so the agent batch is `.notNeeded` and succeeded.
        XCTAssertNil(manager.lifecycleReport)
        // The manager fails closed before entering any lifecycle mutation or
        // settle delay; its own fresh inventory gate is the only read attempted.
        XCTAssertEqual(harness.inventoryLoadCount, 0)
        XCTAssertEqual(harness.sleepDurations, [])
        // The manager knows the read failed...
        XCTAssertEqual(manager.processLoadError, "ps timed out")

        // The failure must not be converted into a successful "nothing to do."
        XCTAssertNotEqual(
            result.status,
            .completed,
            "process list was unreadable and nothing was signalled, but the stop reports success: \(result.message)"
        )
        XCTAssertNotEqual(result.message, "No watched app or user helpers found.")
    }

    // MARK: - P8 proof: stale snapshot from a successful refresh that predates the failure

    func testStopFailsWhenStaleSnapshotPredatesTheReadFailure() async {
        let harness = P8LifecycleRuntimeHarness(inventoryResult: .failure(.commandFailed("ps timed out")))
        let preset = presetWithoutLaunchAgentJobs()
        let manager = makeManager(
            inventory: P8QueuedInventory(results: [
                // Last successful watched refresh: the app was not running yet.
                .success([]),
                // Everything afterwards fails, while the app has since been launched.
                .failure(.commandFailed("ps timed out"))
            ]),
            lifecycle: P8RealControllerLifecycleService(runtime: harness.runtime)
        )
        manager.watchedAppsProvider = { [preset] }

        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(manager.snapshots.count, 1, "precondition: a good snapshot exists")
        XCTAssertFalse(manager.snapshots[0].hasAny, "precondition: it predates the app launch")

        let result = await manager.quitAllKillable(preset)

        XCTAssertNotEqual(
            result.status,
            .completed,
            "stop ran against a stale snapshot and an unreadable process list, but reports: \(result.message)"
        )
    }

    // MARK: - Adversarial control: stale running state still yields an explicit read failure

    func testStaleSnapshotShowingAppRunningYieldsFailureNotFalseSuccess() async {
        let harness = P8LifecycleRuntimeHarness(inventoryResult: .failure(.commandFailed("ps timed out")))
        let preset = presetWithoutLaunchAgentJobs()
        let manager = makeManager(
            inventory: P8QueuedInventory(results: [
                .success([process(pid: 42, name: "Example")]),
                .failure(.commandFailed("ps timed out"))
            ]),
            lifecycle: P8RealControllerLifecycleService(runtime: harness.runtime)
        )
        manager.watchedAppsProvider = { [preset] }

        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertTrue(manager.snapshots[0].isMainRunning, "precondition: stale snapshot says running")

        let result = await manager.quitAllKillable(preset)

        XCTAssertEqual(result.status, .failed)
        // The read failure is now named explicitly rather than being reported as a
        // conclusion about the process ("may still run"), which was itself inferred
        // from the stale snapshot.
        XCTAssertEqual(result.message, "Could not read the process list; Example was not stopped.")
    }

    // MARK: - Helpers

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        lifecycle: any ProcessLifecycleServicing
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: P8NoopSignaler(),
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        return manager
    }

    private func presetWithoutLaunchAgentJobs() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
    }

    private func process(pid: Int32, name: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: getuid(),
            cpu: 0,
            memoryMB: 0,
            command: name == "Example"
                ? "/Applications/Example.app/Contents/MacOS/Example"
                : "/Applications/Example.app/Contents/MacOS/\(name)",
            executablePath: name == "Example"
                ? "/Applications/Example.app/Contents/MacOS/Example"
                : "/Applications/Example.app/Contents/MacOS/\(name)",
            elapsedTime: "00:10",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

// MARK: - Real controller behind the ProcessManager seam

private struct P8RealControllerLifecycleService: ProcessLifecycleServicing {
    let runtime: ProcessLifecycleRuntime

    func appBundleExists(at path: String) -> Bool {
        runtime.fileExists(path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange(runtime: runtime)
    }

    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: preset.mainProcessName,
            forceIfStillRunning: true,
            expectedExecutableDirectory: preset.mainExecutableDirectory,
            runtime: runtime
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            forceIfStillRunning: true,
            expectedExecutableDirectory: preset.bundleContentsDirectory,
            runtime: runtime
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name, runtime: runtime)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: runtime)
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: runtime)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset, runtime: runtime)
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(
            name,
            timeoutSeconds: timeoutSeconds,
            runtime: runtime
        )
    }

    func openAppBundle(at path: String) async -> Bool {
        await ProcessLifecycleController.openAppBundle(at: path, runtime: runtime)
    }
}

// MARK: - Fakes (same shape as ProcessLifecycleMatchingTests.LifecycleRuntimeHarness)

private final class P8LifecycleRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let inventoryResult: Result<[AppProcess], ProcessInventoryError>
    private var recordedCommands: [String] = []
    private var recordedSleepDurations: [UInt64] = []
    private var recordedInventoryLoads = 0

    init(inventoryResult: Result<[AppProcess], ProcessInventoryError>) {
        self.inventoryResult = inventoryResult
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { _ in false },
            runCommand: { [self] command, _ in
                lock.withLock {
                    recordedCommands.append(command)
                    return ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: "No fake command result configured.",
                        exitCode: -1
                    )
                }
            },
            loadProcessInventory: { [self] in
                lock.withLock { recordedInventoryLoads += 1 }
                return inventoryResult
            },
            sleep: { [self] duration in
                lock.withLock {
                    recordedSleepDurations.append(duration)
                }
            }
        )
    }

    var commands: [String] {
        lock.withLock { recordedCommands }
    }

    var sleepDurations: [UInt64] {
        lock.withLock { recordedSleepDurations }
    }

    var inventoryLoadCount: Int {
        lock.withLock { recordedInventoryLoads }
    }
}

private final class P8QueuedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            guard results.count > 1 else {
                return results.first ?? .failure(.commandFailed("No fake result configured."))
            }
            return results.removeFirst()
        }
    }
}

private final class P8NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}
