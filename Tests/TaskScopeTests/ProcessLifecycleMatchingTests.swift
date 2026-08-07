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

    func testUnrelatedPortListenerCannotSatisfyDaemonReadiness() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/daemons/example.plist"],
            commandResults: [
                result(exitCode: 0),
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
            existingPaths: ["/daemons/example.plist"],
            commandResults: [
                result(exitCode: 0),
                result(exitCode: 0)
            ],
            inventory: [
                process(pid: 42, command: "/Applications/ExampleDaemon"),
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
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            systemLaunchDaemonJobs: [
                SystemLaunchDaemonJob(
                    label: "example.daemon",
                    plistPath: "/daemons/example.plist",
                    processName: "ExampleDaemon",
                    servicePort: 443
                )
            ]
        )
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
    private var commandResults: [ShellCommandResult]
    private let inventory: [AppProcess]
    private var recordedCommands: [String] = []
    private var recordedSleepDurations: [UInt64] = []

    init(
        existingPaths: Set<String>,
        commandResults: [ShellCommandResult],
        inventory: [AppProcess] = []
    ) {
        self.existingPaths = existingPaths
        self.commandResults = commandResults
        self.inventory = inventory
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in
                existingPaths.contains(path)
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
                .success(inventory)
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
}
