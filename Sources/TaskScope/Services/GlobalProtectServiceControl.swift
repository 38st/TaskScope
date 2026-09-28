import Foundation

extension ProcessLifecycleController {
    /// Only an explicit Keep Off action may request privileges. Background
    /// enforcement verifies the system state without prompting or changing it.
    static func disableSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        allowAdministratorPrompt: Bool,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        guard preset.hasCanonicalGlobalProtectIdentity else { return .notNeeded }
        let job = WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0]
        let before = await systemOffState(job, runtime: runtime)
        guard let before else {
            return systemResult(job, .verified, "System VPN service is disabled persistently and unloaded.")
        }
        guard allowAdministratorPrompt else {
            return systemResult(job, .failed, "\(before) Choose Apply Keep Off to stop the system VPN service with administrator approval.")
        }
        // Retain a usable restoration path before introducing a persistent
        // disable override. Never move, rewrite, or remove vendor files.
        guard runtime.fileExists(job.plistPath),
              runtime.launchAgentLabel(job.plistPath) == job.label else {
            return systemResult(job, .failed, "The system service plist is missing or its label does not match. Nothing was disabled; restoration could not be guaranteed.")
        }
        let result = await requestAdminServiceChange(adminDisableScript(for: job), runtime: runtime)
        let remaining = await systemOffState(job, runtime: runtime)
        guard result.succeeded, remaining == nil else {
            let failure = result.succeeded ? "" : "Administrator stop failed or was cancelled (\(result.failureDescription)). "
            return systemResult(job, .failed, "\(failure)\(remaining ?? "The service is off, but the administrator command did not finish successfully.") Choose Open to restore GlobalProtect or Apply Keep Off to retry.")
        }
        return systemResult(job, .changed, "System VPN service disabled persistently and unloaded; Open restores the required services without reinstalling.")
    }

    /// Restores a required system override; bootstrap belongs to Open. When the
    /// installed session agent supplies PanGPS, keep an unused system daemon
    /// disabled so every Open/Keep Off cycle does not request root privileges.
    static func enableSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        guard preset.hasCanonicalGlobalProtectIdentity else { return .notNeeded }
        let job = WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0]
        let before = await systemDisabledState(job, runtime: runtime)
        switch before {
        case .enabled, .noOverride:
            return systemResult(job, .verified, "No persistent system disable override; no process was started.")
        case .unknown:
            return systemResult(job, .failed, "Could not read the system service disable override. Refresh and try again; no system state was changed.")
        case .disabled:
            break
        }
        let sessionJob = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        if runtime.fileExists(sessionJob.plistPath) {
            guard runtime.launchAgentLabel(sessionJob.plistPath) == sessionJob.label else {
                return systemResult(job, .failed, "The installed login-session service plist has an unreadable or mismatched label. The system disable override was preserved; no administrator command was requested.")
            }
            return systemResult(job, .verified, "This installation uses the login-session VPN service. The separate system daemon remains disabled; no administrator approval is needed to restore the session service.")
        }
        let script = "/bin/launchctl enable \(ShellCommandRunner.shellQuoted("system/\(job.label)"))"
        let result = await requestAdminServiceChange(script, runtime: runtime)
        let after = await systemDisabledState(job, runtime: runtime)
        guard result.succeeded, after == .enabled else {
            return systemResult(job, .failed, "Could not verify that the system service was re-enabled. Administrator approval may have been cancelled or policy may have rejected the change. Choose Open to retry.")
        }
        return systemResult(job, .changed, "Persistent system disable cleared and verified; no process was started.")
    }

    static func adminDisableScript(for job: SystemLaunchDaemonJob) -> String {
        let target = ShellCommandRunner.shellQuoted("system/\(job.label)")
        return """
        /bin/launchctl disable \(target) || exit $?
        if /bin/launchctl print \(target) >/dev/null 2>&1; then
          /bin/launchctl bootout \(target)
        fi
        """
    }

    private static func requestAdminServiceChange(
        _ script: String, runtime: ProcessLifecycleRuntime
    ) async -> ShellCommandResult {
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(script)) with administrator privileges"
        // The daemon declares ExitTimeOut=20; allow time for authorization plus
        // launchd's graceful shutdown. No direct signal is sent to PanGPS.
        return await runtime.runCommand(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))", 90
        )
    }

    private static func systemDisabledState(
        _ job: SystemLaunchDaemonJob, runtime: ProcessLifecycleRuntime
    ) async -> GlobalProtectCompatibilityReport.DisabledState {
        let result = await runtime.runCommand("/bin/launchctl print-disabled system", 15)
        return GlobalProtectCompatibilityChecker.disabledState(result, label: job.label)
    }

    /// nil means both independent launchd checks succeeded. A failed, timed-out,
    /// or unrecognized probe never establishes that the service is off.
    private static func systemOffState(
        _ job: SystemLaunchDaemonJob, runtime: ProcessLifecycleRuntime
    ) async -> String? {
        let disabled = await systemDisabledState(job, runtime: runtime)
        let result = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted("system/\(job.label)"))", 15
        )
        guard GlobalProtectCompatibilityChecker.loadedState(result, service: .pangpsd) == .notLoaded else {
            return "The system VPN service is still loaded or its state could not be verified."
        }
        guard disabled == .disabled else {
            return "The persistent system disable override is not verified; the VPN service could start again."
        }
        return nil
    }

    private static func systemResult(
        _ job: SystemLaunchDaemonJob, _ state: LifecycleJobState, _ detail: String
    ) -> LifecycleBatchResult {
        LifecycleBatchResult(jobs: [LifecycleJobResult(label: job.label, state: state, detail: detail)])
    }
}
