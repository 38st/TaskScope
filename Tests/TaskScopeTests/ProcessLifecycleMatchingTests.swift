import XCTest
@testable import TaskScope

final class ProcessLifecycleMatchingTests: XCTestCase {
    func testConfiguredNamesAreMatchedAsExactLiteralBasenames() {
        let names = [
            "Codex (Renderer)",
            "a.b",
            "worker+child",
            "name[1]",
            "contains spaces",
            "-leading-dash"
        ]
        let inventory = names.enumerated().map { offset, name in
            process(pid: Int32(offset + 10), command: "/Applications/\(name)")
        } + [
            process(pid: 90, command: "/Applications/Codex Renderer"),
            process(pid: 91, command: "/Applications/aXb"),
            process(pid: 92, command: "/Applications/workerchild"),
            process(pid: 93, command: "/Applications/name1")
        ]

        for name in names {
            XCTAssertEqual(
                ProcessLifecycleController.matchingProcesses(named: name, in: inventory).map(\.name),
                [name]
            )
        }
    }

    func testMatchingDoesNotUseArgumentsOrSubstrings() {
        let inventory = [
            process(pid: 10, command: "/Applications/Example"),
            process(pid: 11, command: "/Applications/Example Helper"),
            process(pid: 12, command: "/Applications/Other")
        ]

        XCTAssertEqual(
            ProcessLifecycleController.matchingProcesses(named: "Example", in: inventory).map(\.pid),
            [10]
        )
    }

    func testTerminationTargetsExcludeTaskScopeAndScopeMainExecutableDirectory() {
        var spoofedArgv = process(
            pid: 13,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        spoofedArgv.executablePath = "/tmp/Example"
        let inventory = [
            process(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example"),
            process(pid: 11, command: "/tmp/Example"),
            process(pid: 12, command: "/Applications/Example.app/Contents/MacOS/Example"),
            spoofedArgv
        ]

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "Example",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
                excludingPID: 12,
                in: inventory
            ).map(\.pid),
            [10]
        )
    }

    func testScopedTerminationUsesKernelExecutableNameWhenProcessNameIsTruncated() {
        var target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        target.command = "/Applications/Ex"

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "Example",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
                excludingPID: 99,
                in: [target]
            ).map(\.pid),
            [10]
        )
    }

    func testPresetOpenVerificationRequiresExecutablePathFromLivePSSchema() async {
        let expectedDirectory = "/Applications/Example.app/Contents/MacOS/"
        let validRuntime = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [
                process(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example")
            ]
        ).runtime
        var spoofedArgv = process(
            pid: 11,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        spoofedArgv.executablePath = "/tmp/Example"
        let spoofedArgvRuntime = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [spoofedArgv]
        ).runtime

        let validResult = await ProcessLifecycleController.waitForProcessNamed(
            "Example",
            timeoutSeconds: 0,
            expectedExecutableDirectory: expectedDirectory,
            runtime: validRuntime
        )
        let spoofedResult = await ProcessLifecycleController.waitForProcessNamed(
            "Example",
            timeoutSeconds: 0,
            expectedExecutableDirectory: expectedDirectory,
            runtime: spoofedArgvRuntime
        )

        XCTAssertTrue(validResult)
        XCTAssertFalse(spoofedResult)
    }

    func testScopedTerminationRechecksKernelPathAndNeverSignalsForgedArgv() async {
        var forged = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        // Even if a stale/compromised inventory row appears in-bundle, the
        // signal-time proc_pidpath result is authoritative.
        forged.executablePath = "/Applications/Example.app/Contents/MacOS/Example"
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [forged],
            executablePathsAtSignal: [10: "/tmp/Example"]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testScopedTerminationFailsClosedWhenKernelPathCannotBeResolved() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            executablePathsAtSignal: [:]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testScopedTerminationRejectsExecToDifferentBinaryInsideSameBundle() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            executablePathsAtSignal: [
                10: "/Applications/Example.app/Contents/Library/LaunchServices/Other"
            ]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testTerminationReportsRejectedSignal() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            signalResults: [false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalRejected)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    func testTerminationReportsUnavailableEscalationInventory() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventoryResults: [
                .success([target]),
                .failure(.commandFailed("ps timed out"))
            ],
            executablePathsAtSignal: [target.pid: target.command]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .escalationUnavailable)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    func testTerminationReportsRejectedEscalationSignal() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            signalResults: [true, false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalRejected)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM, SIGKILL])
    }

    func testRejectedTermIsNotReportedAsFailureWhenCapturedTargetExited() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventoryResults: [.success([target]), .success([])],
            executablePathsAtSignal: [target.pid: target.executablePath!],
            signalResults: [false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .targetsExited)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    func testHelperTerminationTargetsAreRestrictedToConfiguredAppBundle() {
        let inventory = [
            process(pid: 10, command: "/Applications/Example.app/Contents/Library/LaunchServices/ExampleHelper"),
            process(pid: 11, command: "/tmp/ExampleHelper")
        ]

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "ExampleHelper",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/",
                excludingPID: 99,
                in: inventory
            ).map(\.pid),
            [10]
        )
    }

    func testLaunchctlInspectionDistinguishesNotLoadedFromOperationalFailure() {
        let loaded = ShellCommandResult(
            command: "launchctl print",
            stdout: "service = example",
            stderr: "",
            exitCode: 0
        )
        let notLoaded = ShellCommandResult(
            command: "launchctl print",
            stdout: "",
            stderr: "Could not find service \"example\" in domain for user",
            exitCode: 113
        )
        let failed = ShellCommandResult(
            command: "launchctl print",
            stdout: "",
            stderr: "Operation not permitted",
            exitCode: 1
        )

        XCTAssertEqual(ProcessLifecycleController.launchJobInspection(from: loaded), .loaded)
        XCTAssertEqual(ProcessLifecycleController.launchJobInspection(from: notLoaded), .notLoaded)
        XCTAssertEqual(
            ProcessLifecycleController.launchJobInspection(from: failed),
            .failed("Operation not permitted")
        )
    }

    func testLoadedAgentWithMissingPlistIsUnloadedAndCountsAsSuccess() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [
                result(exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/missing/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.count, 1)
        // The job was loaded, was booted out, and the unload was verified. An absent
        // plist is not a reason to call that stop a failure.
        XCTAssertEqual(batch.jobs[0].state, .changed)
        XCTAssertTrue(batch.jobs[0].succeeded)
        XCTAssertTrue(batch.succeeded)
        XCTAssertTrue(batch.jobs[0].detail.contains("still unloaded and verified"))
        XCTAssertTrue(harness.commands.contains { $0.contains("launchctl bootout") })
        XCTAssertEqual(harness.timeouts, [15, 30, 15])
        XCTAssertEqual(harness.sleepDurations, [300_000_000])
    }

    func testLaunchctlInspectionFailureDoesNotPretendAgentWasUnloaded() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(stderr: "Operation not permitted", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("Operation not permitted") == true)
        XCTAssertFalse(harness.commands.contains { $0.contains("launchctl bootout") })
    }

    func testAgentBootstrapExecutesAndVerifiesThroughInjectedRuntime() async throws {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0),
                result(exitCode: 0),
                result(exitCode: 0),
                result(exitCode: 0)
            ]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertEqual(
            harness.commands.filter { $0.contains("/bin/launchctl") }.count,
            5
        )
        XCTAssertTrue(harness.commands.contains { $0.contains("bootstrap") })
        XCTAssertTrue(harness.commands.contains { $0.contains("kickstart") })
        let enableIndex = try XCTUnwrap(harness.commands.firstIndex { $0.contains(" enable ") })
        let bootstrapIndex = try XCTUnwrap(harness.commands.firstIndex { $0.contains(" bootstrap ") })
        XCTAssertLessThan(enableIndex, bootstrapIndex, "enable must precede bootstrap")
    }

    /// launchd refuses to bootstrap a job that carries a persistent disable
    /// override, which is exactly the state Keep Off leaves behind. Enabling
    /// after the bootstrap therefore never ran when it mattered.
    func testAgentBootstrapEnablesBeforeBootstrapSoADisabledJobCanLoad() async throws {
        let launchd = DisabledJobLaunchd()
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [],
            respond: { launchd.respond(to: $0) }
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed, batch.jobs.first?.detail ?? "")
        XCTAssertTrue(launchd.loaded)
        let enableIndex = try XCTUnwrap(harness.commands.firstIndex { $0.contains(" enable ") })
        let bootstrapIndex = try XCTUnwrap(harness.commands.firstIndex { $0.contains(" bootstrap ") })
        XCTAssertLessThan(enableIndex, bootstrapIndex)
    }

    func testAgentBootstrapRejectsMismatchedPlistLabelBeforeMutation() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "actual.agent"],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("actual.agent") == true)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    func testAgentBootstrapReportsEnableFailureAndDoesNotBootstrapOrKickstart() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(stderr: "Operation not permitted", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertEqual(batch.jobs.first?.detail, "Operation not permitted")
        XCTAssertFalse(harness.commands.contains { $0.contains(" bootstrap ") })
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })
    }

    func testOpenAppBundleDoesNotForceASecondInstance() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Applications/Example.app"],
            commandResults: [result(exitCode: 0)]
        )

        let opened = await ProcessLifecycleController.openAppBundle(
            at: "/Applications/Example.app",
            runtime: harness.runtime
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.commands, ["/usr/bin/open '/Applications/Example.app'"])
    }

    /// On some GlobalProtect layouts the `pangpa` agent's Program is the main
    /// GlobalProtect binary. Quit Helpers must leave that agent loaded or it
    /// quits the app the user asked to keep.
    func testUnloadLeavesAgentThatRunsThePreservedMainProcessLoaded() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [result(stdout: "state = running\n\tpid = 42", exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            preservingPIDs: [42],
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .alreadyLoaded)
        XCTAssertTrue(batch.succeeded)
        XCTAssertTrue(batch.jobs.first?.detail.contains("pid 42") == true)
        XCTAssertFalse(harness.commands.contains { $0.contains("bootout") })
    }

    func testUnloadStillBootsOutAgentsThatDoNotRunAPreservedProcess() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(stdout: "state = running\n\tpid = 43", exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            preservingPIDs: [42],
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertTrue(harness.commands.contains { $0.contains("bootout") })
    }

    func testLoadedAgentIsLeftRunningWithoutRestart() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [result(stdout: "pid = 42", exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .alreadyLoaded)
        XCTAssertEqual(batch.jobs.first?.detail, "Already loaded; no restart needed.")
        XCTAssertFalse(harness.commands.contains { $0.contains("bootstrap") })
        XCTAssertFalse(harness.commands.contains { $0.contains(" enable ") })
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })
    }

    func testKeepOffDisablesAndBootsOutLoadedUserAgent() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(exitCode: 0),
                result(stdout: "pid = 42", exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.disableUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertEqual(
            harness.commands,
            [
                "/bin/launchctl disable 'gui/501/example.agent'",
                "/bin/launchctl print 'gui/501/example.agent'",
                "/bin/launchctl bootout 'gui/501/example.agent'",
                "/bin/launchctl print 'gui/501/example.agent'"
            ]
        )
    }

    func testAllowToRunClearsDisableWithoutStartingAgent() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [result(exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.enableUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(
            harness.commands,
            ["/bin/launchctl enable 'gui/501/example.agent'"]
        )
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })
        XCTAssertFalse(harness.commands.contains { $0.contains("bootstrap") })
    }

    func testMissingOptionalAgentDoesNotBlockOpen() async {
        var preset = presetWithAgent(plistPath: "/agents/optional.plist")
        preset.userLaunchAgentJobs[0].isRequired = false
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: preset,
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(batch.jobs.first?.state, .alreadyUnloaded)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    /// A loaded daemon whose reported pid is not running the expected process is
    /// waited on, never restarted, and never re-bootstrapped with privileges.
    func testLoadedDaemonWithoutMatchingProcessIsWaitedOnNotRestarted() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [],
            respond: { _ in
                ShellCommandResult(command: "", stdout: "state = running\n\tpid = 42", stderr: "", exitCode: 0)
            },
            inventory: [
                process(pid: 99, command: "/Applications/UnrelatedListener")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("never restarts") == true)
        XCTAssertFalse(harness.sleepDurations.isEmpty, "readiness must be re-polled before failing")
        XCTAssertFalse(harness.commands.contains { $0.contains("/usr/sbin/lsof") })
        XCTAssertFalse(harness.commands.contains { $0.contains("/usr/bin/osascript") })
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })
    }

    /// Readiness is launchd's pid plus a fresh inventory. An unprivileged `lsof`
    /// cannot see a root daemon's descriptors, so a port probe could only ever
    /// fail and used to make every Open fall into the administrator script.
    func testDaemonReadinessIsVerifiedFromLaunchdPIDAndInventoryWithoutLsof() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stdout: "state = running\n\tpid = 42", exitCode: 0)
            ],
            inventory: [
                process(pid: 42, command: "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS"),
                process(pid: 99, command: "/Applications/UnrelatedListener")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .verified)
        XCTAssertEqual(
            harness.commands,
            ["/bin/launchctl print 'system/com.paloaltonetworks.gp.pangpsd'"]
        )
        XCTAssertFalse(harness.commands.contains { $0.contains("lsof") })
        XCTAssertFalse(harness.commands.contains { $0.contains("osascript") })
    }

    func testDaemonReadinessRejectsSameNameProcessWhosePIDIsNotLaunchdJobPID() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [],
            respond: { _ in
                ShellCommandResult(command: "", stdout: "pid = 42", stderr: "", exitCode: 0)
            },
            inventory: [
                process(pid: 99, command: "/tmp/PanGPS")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: .globalProtect,
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertFalse(harness.commands.contains { $0.contains("/usr/sbin/lsof") })
        XCTAssertFalse(harness.commands.contains { $0.contains("/usr/bin/osascript") })
    }

    /// The privileged script bootstraps only a daemon launchd does not have
    /// loaded. `kickstart -k` on the live VPN daemon would drop the session, so
    /// it must never appear in the script, loaded or not.
    func testEnsureSystemLaunchDaemonsNeverKickstartsTheSystemDaemon() async throws {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0),
                result(stdout: "state = running\n\tpid = 42", exitCode: 0)
            ],
            inventory: [
                process(pid: 42, command: "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: .globalProtect,
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        let adminCommand = try XCTUnwrap(harness.commands.first { $0.contains("/usr/bin/osascript") })
        XCTAssertFalse(adminCommand.contains("kickstart"))
        XCTAssertTrue(adminCommand.contains("launchctl bootstrap system"))
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })

        let script = ProcessLifecycleController.adminBootstrapScript(
            for: WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0]
        )
        XCTAssertFalse(script.contains("kickstart"))
        XCTAssertTrue(script.contains("exit 0"), "a loaded daemon must be left alone")
        XCTAssertTrue(script.contains("/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist'"))
    }

    func testCustomDaemonConfigurationNeverReachesPrivilegedCommandPath() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/example.plist"],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: WatchedAppPreset(
                displayName: "Example",
                mainProcessName: "Example",
                helperProcessNames: [],
                protectedProcessNames: [],
                appPath: "/Applications/Example.app",
                systemLaunchDaemonJobs: [
                    SystemLaunchDaemonJob(
                        label: "example.daemon",
                        plistPath: "/Library/LaunchDaemons/example.plist",
                        processName: "ExampleDaemon",
                        servicePort: nil
                    )
                ]
            ),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch, .notNeeded)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    func testLaunchJobPIDRequiresExplicitPositivePIDField() {
        XCTAssertEqual(
            ProcessLifecycleController.launchJobPID(
                from: result(stdout: "state = running\n\tpid = 42", exitCode: 0)
            ),
            42
        )
        XCTAssertNil(
            ProcessLifecycleController.launchJobPID(
                from: result(stdout: "state = running", exitCode: 0)
            )
        )
    }

    private func presetWithAgent(plistPath: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(label: "example.agent", plistPath: plistPath)
            ]
        )
    }

    private func presetWithDaemon() -> WatchedAppPreset {
        .globalProtect
    }

    private func result(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32
    ) -> ShellCommandResult {
        ShellCommandResult(
            command: "fake",
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode
        )
    }

    private func process(pid: Int32, command: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: command,
            executablePath: command.hasPrefix("/") ? command : nil,
            elapsedTime: "00:01",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }
}

/// A fake launchd that mirrors the real one's refusal to bootstrap a job that
/// still carries a persistent disable override.
private final class DisabledJobLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private(set) var loaded = false

    func respond(to command: String) -> ShellCommandResult {
        lock.withLock {
            if command.contains(" print ") {
                return loaded
                    ? ShellCommandResult(command: command, stdout: "pid = 42", stderr: "", exitCode: 0)
                    : ShellCommandResult(command: command, stdout: "", stderr: "Could not find service", exitCode: 113)
            }
            if command.contains(" enable ") {
                enabled = true
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
            }
            if command.contains(" bootstrap ") {
                guard enabled else {
                    return ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: "Bootstrap failed: 5: Input/output error",
                        exitCode: 5
                    )
                }
                loaded = true
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
            }
            if command.contains(" kickstart ") {
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: loaded ? 0 : 1)
            }
            return ShellCommandResult(command: command, stdout: "", stderr: "unexpected command", exitCode: 1)
        }
    }
}

private final class LifecycleRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private let launchAgentLabels: [String: String]
    private var commandResults: [ShellCommandResult]
    private let respond: (@Sendable (String) -> ShellCommandResult)?
    private var inventoryResults: [Result<[AppProcess], ProcessInventoryError>]
    private let executablePathsAtSignal: [Int32: String]
    private var signalResults: [Bool]
    private var recordedCommands: [String] = []
    private var recordedTimeouts: [TimeInterval] = []
    private var recordedSleepDurations: [UInt64] = []
    private var recordedSignals: [(Int32, Int32)] = []

    init(
        existingPaths: Set<String>,
        launchAgentLabels: [String: String] = [:],
        commandResults: [ShellCommandResult],
        respond: (@Sendable (String) -> ShellCommandResult)? = nil,
        inventory: [AppProcess] = [],
        inventoryResults: [Result<[AppProcess], ProcessInventoryError>]? = nil,
        executablePathsAtSignal: [Int32: String]? = nil,
        signalResults: [Bool] = [true]
    ) {
        self.existingPaths = existingPaths
        self.launchAgentLabels = launchAgentLabels
        self.commandResults = commandResults
        self.respond = respond
        self.inventoryResults = inventoryResults ?? [.success(inventory)]
        self.executablePathsAtSignal = executablePathsAtSignal
            ?? Dictionary(uniqueKeysWithValues: inventory.compactMap { process in
                process.executablePath.map { (process.pid, $0) }
            })
        self.signalResults = signalResults
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in
                existingPaths.contains(path)
            },
            launchAgentLabel: { [self] path in
                launchAgentLabels[path]
            },
            runCommand: { [self] command, timeout in
                lock.withLock {
                    recordedCommands.append(command)
                    recordedTimeouts.append(timeout)
                    if let respond {
                        return respond(command)
                    }
                    guard !commandResults.isEmpty else {
                        return ShellCommandResult(
                            command: command,
                            stdout: "",
                            stderr: "No fake command result configured.",
                            exitCode: -1
                        )
                    }
                    var response = commandResults.removeFirst()
                    response.command = command
                    return response
                }
            },
            loadProcessInventory: { [self] in
                lock.withLock {
                    guard inventoryResults.count > 1 else {
                        return inventoryResults.first
                            ?? .failure(.commandFailed("No fake inventory result configured."))
                    }
                    return inventoryResults.removeFirst()
                }
            },
            executablePathForPID: { [self] pid in
                executablePathsAtSignal[pid]
            },
            sendSignal: { [self] signal, pid in
                lock.withLock {
                    recordedSignals.append((signal, pid))
                    guard signalResults.count > 1 else {
                        return signalResults.first ?? false
                    }
                    return signalResults.removeFirst()
                }
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

    var timeouts: [TimeInterval] {
        lock.withLock { recordedTimeouts }
    }

    var sleepDurations: [UInt64] {
        lock.withLock { recordedSleepDurations }
    }

    var signals: [(Int32, Int32)] {
        lock.withLock { recordedSignals }
    }
}
