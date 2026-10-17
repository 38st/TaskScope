import Foundation

struct GlobalProtectServiceObservation: Equatable, Sendable {
    enum State: Equatable, Sendable { case absent, running, unknown }
    var session: State
    var system: State

    /// Names and effective UID alone cannot identify another login session's
    /// setuid PanGPS. Only the fixed local jobs and a kernel product path count.
    static func read(runtime: ProcessLifecycleRuntime = .live) async -> Self {
        func state(for service: GlobalProtectCompatibilityReport.Service) async -> State {
            let domain = service.isSystem ? "system" : "gui/\(runtime.userID)"
            let inspection = await runtime.runCommand(
                "/bin/launchctl print \(ShellCommandRunner.shellQuoted("\(domain)/\(service.label)"))", 15
            )
            switch GlobalProtectCompatibilityChecker.loadedState(inspection, service: service) {
            case .notLoaded:
                return .absent
            case .unknown:
                return .unknown
            case .loaded:
                guard let pid = ProcessLifecycleController.launchJobPID(from: inspection) else {
                    return hasNoRunningPID(inspection.stdout) ? .absent : .unknown
                }
                guard case .success(let inventory) = await runtime.loadProcessInventory(),
                      var process = inventory.first(where: { $0.pid == pid }),
                      process.uid == 0 || (!service.isSystem && process.uid == runtime.userID),
                      let path = runtime.executablePathForPID(pid) else { return .unknown }
                process.executablePath = path
                return GlobalProtectCompatibilityChecker.trustedName(process) == .panGPS ? .running : .unknown
            }
        }
        let session = await state(for: .pangps)
        let system = await state(for: .pangpsd)
        return Self(session: session, system: system)
    }

    /// A complete job listing with state but no top-level PID describes a
    /// loaded job without a running process. Empty, truncated, or malformed PID
    /// output remains unknown rather than bypassing service attribution.
    private static func hasNoRunningPID(_ output: String) -> Bool {
        var depth = 0
        var sawRoot = false
        var sawState = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if depth == 1 {
                if line.hasPrefix("pid") { return false }
                if line.hasPrefix("state = "), line.count > 8 { sawState = true }
            }
            if line.hasSuffix("{") {
                if depth == 0 {
                    guard !sawRoot, line.hasSuffix(" = {") else { return false }
                    sawRoot = true
                }
                depth += 1
            } else if line == "}" {
                depth -= 1
                if depth < 0 { return false }
            } else if depth == 0, !line.isEmpty {
                return false
            }
        }
        return sawRoot && sawState && depth == 0
    }
}

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
        let sessionJob = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        let preservesLoadedDaemon = runtime.fileExists(sessionJob.plistPath)
        if preservesLoadedDaemon {
            let inspection = await runtime.runCommand(
                "/bin/launchctl print \(ShellCommandRunner.shellQuoted("system/\(job.label)"))", 15
            )
            guard GlobalProtectCompatibilityChecker.loadedState(inspection, service: .pangpsd) == .notLoaded else {
                return systemResult(job, .failed, "The system VPN service is loaded or its state is unknown. Its override and loaded state were preserved because this installation restores the login-session service. Keep Off is incomplete.")
            }
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
        let result = await requestAdminServiceChange(
            adminDisableScript(for: job, preservingLoadedDaemon: preservesLoadedDaemon), runtime: runtime
        )
        let remaining = result.succeeded
            ? await waitForSystemOff(job, runtime: runtime)
            : await systemOffState(job, runtime: runtime)
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
        let sessionJob = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        let usesSessionService = runtime.fileExists(sessionJob.plistPath)
        let before = await systemDisabledState(job, runtime: runtime)
        switch before {
        case .enabled, .noOverride:
            return systemResult(job, .verified, "No persistent system disable override; no process was started.")
        case .unknown where !usesSessionService:
            return systemResult(job, .failed, "Could not read the system service disable override. Refresh and try again; no system state was changed.")
        case .unknown, .disabled:
            // A session installation never changes the system override here, so
            // an unreadable override must not block restoring the session job.
            break
        }
        if usesSessionService {
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

    static func adminDisableScript(for job: SystemLaunchDaemonJob, preservingLoadedDaemon: Bool = false) -> String {
        let target = ShellCommandRunner.shellQuoted("system/\(job.label)")
        // Recheck inside the privileged command in case launchd loaded the
        // daemon while authorization was pending.
        let preserve = preservingLoadedDaemon
            ? "if /bin/launchctl print \(target) >/dev/null 2>&1; then exit 1; fi\n" : ""
        return preserve + """
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
        _ job: SystemLaunchDaemonJob, timeout: TimeInterval = 15, runtime: ProcessLifecycleRuntime
    ) async -> GlobalProtectCompatibilityReport.DisabledState {
        let result = await runtime.runCommand("/bin/launchctl print-disabled system", timeout)
        return GlobalProtectCompatibilityChecker.disabledState(result, label: job.label)
    }

    /// nil means both independent launchd checks succeeded. A failed, timed-out,
    /// or unrecognized probe never establishes that the service is off.
    private static func systemOffState(
        _ job: SystemLaunchDaemonJob, deadline: TimeInterval? = nil, runtime: ProcessLifecycleRuntime
    ) async -> String? {
        let remaining = deadline.map { $0 - runtime.systemUptime() } ?? 15
        guard remaining > 0, !Task.isCancelled else { return "System stop verification did not complete." }
        let disabled = await systemDisabledState(job, timeout: min(remaining, 15), runtime: runtime)
        let printRemaining = deadline.map { $0 - runtime.systemUptime() } ?? 15
        guard printRemaining > 0, !Task.isCancelled else { return "System stop verification did not complete." }
        let result = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted("system/\(job.label)"))", min(printRemaining, 15)
        )
        guard GlobalProtectCompatibilityChecker.loadedState(result, service: .pangpsd) == .notLoaded else {
            return "The system VPN service is still loaded or its state could not be verified."
        }
        guard disabled == .disabled else {
            return "The persistent system disable override is not verified; the VPN service could start again."
        }
        return nil
    }

    private static func waitForSystemOff(
        _ job: SystemLaunchDaemonJob, runtime: ProcessLifecycleRuntime
    ) async -> String? {
        let deadline = runtime.systemUptime() + 30
        var remaining: String? = "System stop verification did not complete."
        for attempt in 0...60 {
            guard runtime.systemUptime() < deadline, !Task.isCancelled else { break }
            remaining = await systemOffState(job, deadline: deadline, runtime: runtime)
            guard remaining != nil else { return nil }
            let sleepSeconds = min(0.5, deadline - runtime.systemUptime())
            guard sleepSeconds > 0, !Task.isCancelled else { break }
            if attempt < 60 { await runtime.sleep(UInt64(sleepSeconds * 1_000_000_000)) }
        }
        return remaining
    }

    private static func systemResult(
        _ job: SystemLaunchDaemonJob, _ state: LifecycleJobState, _ detail: String
    ) -> LifecycleBatchResult {
        LifecycleBatchResult(jobs: [LifecycleJobResult(label: job.label, state: state, detail: detail)])
    }
}
