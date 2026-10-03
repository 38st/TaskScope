import Foundation
import XCTest
@testable import TaskScope

final class GlobalProtectServiceControlTests: XCTestCase {
    func testExplicitStopDisablesAndUnloadsThenRestoresWithoutChangingFiles() async {
        let harness = ServiceHarness()
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        XCTAssertTrue(stopped.succeeded)
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(restored.succeeded)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(enabled.succeeded)
        let final = await harness.state
        XCTAssertFalse(final.disabled)
        XCTAssertTrue(final.loaded)
        let commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 2)
        XCTAssertFalse(commands.contains { $0.contains("kickstart") || $0.contains("/bin/rm") || $0.contains("/bin/mv") || $0.contains("kill ") })
    }

    func testCancelledBootstrapPreservesDisableOverrideWithOnePrompt() async {
        let harness = ServiceHarness(disabled: true, loaded: false, adminFailure: .cancelled)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)

        XCTAssertFalse(restored.succeeded)
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)
        let commands = await harness.commands
        let adminCommands = commands.filter { $0.contains("osascript") }
        XCTAssertEqual(adminCommands.count, 1)
        XCTAssertTrue(adminCommands.first?.contains("launchctl enable") == true)
        XCTAssertTrue(adminCommands.first?.contains("launchctl bootstrap") == true)
    }

    func testLoadedDaemonClearsOverrideWithoutBootstrapping() async {
        let harness = ServiceHarness(disabled: true, loaded: true)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)

        XCTAssertTrue(restored.succeeded)
        XCTAssertTrue(enabled.succeeded)
        let state = await harness.state
        XCTAssertFalse(state.disabled)
        XCTAssertTrue(state.loaded)
        let commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
        XCTAssertFalse(commands.contains { $0.contains("bootstrap") })
    }

    func testBackgroundEnforcementNeverPromptsOrMutatesSystemState() async {
        for disabled in [false, true] {
            for loaded in [false, true] {
                let harness = ServiceHarness(disabled: disabled, loaded: loaded)
                let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                    for: .globalProtect, allowAdministratorPrompt: false, runtime: harness.runtime
                )
                XCTAssertEqual(result.succeeded, disabled && !loaded)
                let commands = await harness.commands
                XCTAssertFalse(commands.contains { $0.contains("osascript") })
                let state = await harness.state
                XCTAssertEqual(state.disabled, disabled)
                XCTAssertEqual(state.loaded, loaded)
            }
        }
    }

    func testCancelledAdministratorStopAndPartialBootoutFailureAreReported() async {
        for failure in [ServiceHarness.AdminFailure.cancelled, .bootoutFailed] {
            let harness = ServiceHarness(adminFailure: failure)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
            )
            XCTAssertFalse(stopped.succeeded)
            XCTAssertTrue(stopped.failureSummary?.contains("Open") == true)
            let state = await harness.state
            XCTAssertTrue(state.loaded)
            XCTAssertEqual(state.disabled, failure == .bootoutFailed)
        }
    }

    func testFailedAndUnknownProbesNeverClaimOffOrEnabled() async {
        let probes: [ShellCommandResult] = [
            .init(command: "", stdout: "", stderr: "Access denied", exitCode: 1),
            .init(command: "", stdout: "new output format", stderr: "", exitCode: 0),
            .init(command: "", stdout: "", stderr: "Could not find service", exitCode: ShellCommandRunner.timedOutExitCode),
            .init(command: "", stdout: "", stderr: "cancelled", exitCode: ShellCommandRunner.cancelledExitCode)
        ]
        for probe in probes {
            let harness = ServiceHarness(disabled: true, loaded: false, disabledProbe: probe)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: false, runtime: harness.runtime
            )
            let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
            XCTAssertFalse(stopped.succeeded)
            XCTAssertFalse(enabled.succeeded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
        }
    }

    func testUnrecognizedAbsenceAndInterruptedLoadedProbesCannotClaimOff() async {
        for probe in [
            ShellCommandResult(command: "", stdout: "", stderr: "Access denied", exitCode: 113),
            ShellCommandResult(command: "", stdout: "", stderr: "Could not find service \"com.paloaltonetworks.gp.pangpsd\" in domain for system", exitCode: ShellCommandRunner.timedOutExitCode)
        ] {
            var runtime = ServiceHarness(disabled: true, loaded: false).runtime
            let original = runtime.runCommand
            runtime.runCommand = { command, timeout in
                if command.hasPrefix("/bin/launchctl print ") { return probe }
                return await original(command, timeout)
            }
            let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: false, runtime: runtime
            )
            XCTAssertFalse(result.succeeded)
        }
    }

    func testMissingOrMismatchedPlistDoesNotIntroduceDisableOverride() async {
        for label in [nil, "wrong.label"] as [String?] {
            let harness = ServiceHarness(plistLabel: label)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
            )
            XCTAssertFalse(stopped.succeeded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
        }
    }

    func testAlreadyOffAndAlreadyEnabledDoNotPrompt() async {
        let harness = ServiceHarness(disabled: true, loaded: false)
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        XCTAssertTrue(stopped.succeeded)
        var commands = await harness.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") })
        _ = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        _ = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
        let state = await harness.state
        XCTAssertFalse(state.loaded, "Turning Keep Off off must not launch anything")
    }

    func testForgedBuiltInIdentityCannotRequestSystemOperations() async {
        let harness = ServiceHarness()
        var forged = WatchedAppPreset.globalProtect
        forged.systemLaunchDaemonJobs[0].plistPath = "/tmp/evil.plist"
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: forged, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: forged, runtime: harness.runtime)
        XCTAssertEqual(stopped, .notNeeded)
        XCTAssertEqual(enabled, .notNeeded)
        let commands = await harness.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testSessionInstallationPreservesSystemDisableWithoutAdministratorRequest() async {
        let harness = ServiceHarness(disabled: true, loaded: false)
        let session = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        var runtime = harness.runtime
        runtime.fileExists = { $0 == session.plistPath }
        runtime.launchAgentLabel = { $0 == session.plistPath ? session.label : nil }

        // Covers repeated Open / allow-to-run preparation followed by Keep Off.
        for _ in 0..<2 {
            let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertTrue(enabled.succeeded)
            XCTAssertTrue(enabled.jobs.first?.detail.contains("remains disabled") == true)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertTrue(stopped.succeeded)
        }
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)
        let commands = await harness.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") || $0.contains("launchctl enable") || $0.contains("bootstrap") })
    }

    func testInvalidSessionPlistCannotClaimPasswordlessRestoration() async {
        for label in [nil, "wrong.label"] as [String?] {
            let harness = ServiceHarness(disabled: true, loaded: false)
            var runtime = harness.runtime
            runtime.fileExists = { $0 == WatchedAppPreset.globalProtectUserLaunchAgentJobs[1].plistPath }
            runtime.launchAgentLabel = { _ in label }
            let result = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertFalse(result.succeeded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
            let state = await harness.state
            XCTAssertTrue(state.disabled)
        }
    }

    func testPrivilegedDisableScriptParsesAsShell() async {
        let script = ProcessLifecycleController.adminDisableScript(for: WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0])
        let result = await ShellCommandRunner.run("/bin/sh -n -c \(ShellCommandRunner.shellQuoted(script))", timeout: 5)
        XCTAssertTrue(result.succeeded, result.stderr)
    }
}

private actor ServiceHarness {
    enum AdminFailure { case cancelled, bootoutFailed }
    var state: (disabled: Bool, loaded: Bool)
    var commands: [String] = []
    let adminFailure: AdminFailure?
    let plistLabel: String?
    let disabledProbe: ShellCommandResult?
    static let label = "com.paloaltonetworks.gp.pangpsd"

    init(disabled: Bool = false, loaded: Bool = true, adminFailure: AdminFailure? = nil,
         plistLabel: String? = label, disabledProbe: ShellCommandResult? = nil) {
        state = (disabled, loaded)
        self.adminFailure = adminFailure
        self.plistLabel = plistLabel
        self.disabledProbe = disabledProbe
    }

    nonisolated var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in plistLabel != nil && path == "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist" },
            launchAgentLabel: { [self] _ in plistLabel },
            runCommand: { [self] command, _ in await run(command) },
            loadProcessInventory: {
                .success([AppProcess(pid: 42, parentPID: 1, uid: 0, cpu: 0, memoryMB: 0,
                    command: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS",
                    elapsedTime: "00:10", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)])
            },
            sleep: { _ in }
        )
    }

    func run(_ command: String) -> ShellCommandResult {
        commands.append(command)
        if command == "/bin/launchctl print-disabled system" {
            return disabledProbe ?? result("disabled services = {\n\"\(Self.label)\" => \(state.disabled ? "disabled" : "enabled")\n}")
        }
        if command.hasPrefix("/bin/launchctl print ") {
            return state.loaded ? result("pid = 42")
                : result("", error: "Could not find service \"\(Self.label)\" in domain for system", code: 113)
        }
        if command.hasPrefix("/usr/bin/osascript") {
            if adminFailure == .cancelled { return result("", error: "User cancelled", code: 1) }
            if command.contains("launchctl disable") {
                state.disabled = true
                if adminFailure == .bootoutFailed { return result("", error: "Bootout failed", code: 1) }
                state.loaded = false
            } else if command.contains("launchctl bootstrap") {
                state.disabled = false
                state.loaded = true
            } else if command.contains("launchctl enable") {
                state.disabled = false
            }
            return result("")
        }
        return result("", error: "Unexpected command", code: 1)
    }

    func result(_ text: String, error: String = "", code: Int32 = 0) -> ShellCommandResult {
        ShellCommandResult(command: "fixture", stdout: text, stderr: error, exitCode: code)
    }
}
