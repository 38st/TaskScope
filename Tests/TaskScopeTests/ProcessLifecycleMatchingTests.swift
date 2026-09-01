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

    func testAgentBootstrapExecutesAndVerifiesThroughInjectedRuntime() async {
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

    func testAgentBootstrapReportsEnableFailureAndDoesNotKickstart() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0),
                result(stderr: "Operation not permitted", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertEqual(batch.jobs.first?.detail, "Operation not permitted")
        XCTAssertFalse(harness.commands.contains { $0.contains("kickstart") })
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

    func testUnrelatedPortListenerCannotSatisfyDaemonReadiness() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stdout: "pid = 42", exitCode: 0),
                result(stderr: "Administrator approval cancelled", exitCode: 1)
            ],
            inventory: [
                process(pid: 99, command: "/Applications/UnrelatedListener")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertFalse(harness.commands.contains { $0.contains("/usr/sbin/lsof") })
        XCTAssertTrue(harness.commands.contains { $0.contains("/usr/bin/osascript") })
    }

    func testDaemonReadinessScopesPortProbeToExpectedProcessPID() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stdout: "pid = 42", exitCode: 0),
                result(exitCode: 0)
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
        let lsofCommand = harness.commands.first { $0.contains("/usr/sbin/lsof") }
        XCTAssertTrue(lsofCommand?.contains("-p '42'") == true)
        XCTAssertFalse(lsofCommand?.contains("99") == true)
    }

    func testDaemonReadinessRejectsSameNameProcessWhosePIDIsNotLaunchdJobPID() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stdout: "pid = 42", exitCode: 0),
                result(stderr: "Administrator approval cancelled", exitCode: 1)
            ],
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
        XCTAssertTrue(harness.commands.contains { $0.contains("/usr/bin/osascript") })
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

private final class LifecycleRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private let launchAgentLabels: [String: String]
    private var commandResults: [ShellCommandResult]
    private var inventoryResults: [Result<[AppProcess], ProcessInventoryError>]
    private let executablePathsAtSignal: [Int32: String]
    private var signalResults: [Bool]
    private var recordedCommands: [String] = []
    private var recordedSleepDurations: [UInt64] = []
    private var recordedSignals: [(Int32, Int32)] = []

    init(
        existingPaths: Set<String>,
        launchAgentLabels: [String: String] = [:],
        commandResults: [ShellCommandResult],
        inventory: [AppProcess] = [],
        inventoryResults: [Result<[AppProcess], ProcessInventoryError>]? = nil,
        executablePathsAtSignal: [Int32: String]? = nil,
        signalResults: [Bool] = [true]
    ) {
        self.existingPaths = existingPaths
        self.launchAgentLabels = launchAgentLabels
        self.commandResults = commandResults
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
            runCommand: { [self] command, _ in
                lock.withLock {
                    recordedCommands.append(command)
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

    var sleepDurations: [UInt64] {
        lock.withLock { recordedSleepDurations }
    }

    var signals: [(Int32, Int32)] {
        lock.withLock { recordedSignals }
    }
}
