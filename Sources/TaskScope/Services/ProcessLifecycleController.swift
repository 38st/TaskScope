import Foundation

enum LaunchDaemonEnsureResult: Equatable {
    case notNeeded
    case alreadyRunning
    case started
    case failed

    var didChangeState: Bool {
        self == .started
    }

    var messageSuffix: String {
        switch self {
        case .notNeeded, .alreadyRunning:
            ""
        case .started:
            "; service started"
        case .failed:
            "; service not started"
        }
    }
}

enum ProcessLifecycleController {
    static func settleAfterProcessChange() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static func terminateProcess(named name: String, forceIfStillRunning: Bool) async {
        let literalName = ShellCommandRunner.extendedRegexLiteral(name)
        _ = await ShellCommandRunner.run(
            "/usr/bin/pkill -TERM -x \(ShellCommandRunner.shellQuoted(literalName)) 2>/dev/null || true"
        )

        guard forceIfStillRunning else { return }

        await settleAfterProcessChange()
        if await isProcessNamedRunning(name) {
            _ = await ShellCommandRunner.run(
                "/usr/bin/pkill -KILL -x \(ShellCommandRunner.shellQuoted(literalName)) 2>/dev/null || true"
            )
        }
    }

    static func isProcessNamedRunning(_ name: String) async -> Bool {
        let literalName = ShellCommandRunner.extendedRegexLiteral(name)
        let result = await ShellCommandRunner.run(
            "/usr/bin/pgrep -x \(ShellCommandRunner.shellQuoted(literalName)) >/dev/null 2>&1"
        )
        return result.exitCode == 0
    }

    static func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> Bool {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return false }

        for job in jobs.reversed() {
            _ = await ShellCommandRunner.run("""
            uid=$(/usr/bin/id -u)
            label=\(ShellCommandRunner.shellQuoted(job.label))
            plist=\(ShellCommandRunner.shellQuoted(job.plistPath))
            /bin/launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
            /bin/launchctl bootout "gui/$uid" "$plist" >/dev/null 2>&1 || true
            """)
        }

        await settleAfterProcessChange()
        return true
    }

    static func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> Bool {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return false }

        for job in jobs {
            _ = await ShellCommandRunner.run("""
            uid=$(/usr/bin/id -u)
            label=\(ShellCommandRunner.shellQuoted(job.label))
            plist=\(ShellCommandRunner.shellQuoted(job.plistPath))
            [ -f "$plist" ] || exit 0
            /bin/launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 || true
            /bin/launchctl enable "gui/$uid/$label" >/dev/null 2>&1 || true
            /bin/launchctl kickstart -k "gui/$uid/$label" >/dev/null 2>&1 || true
            """)
        }

        await settleAfterProcessChange()
        return true
    }

    static func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LaunchDaemonEnsureResult {
        let jobs = preset.lifecycleSystemLaunchDaemonJobs
        guard !jobs.isEmpty else { return .notNeeded }

        var didStartAny = false

        for job in jobs {
            if await systemLaunchDaemonIsReady(job) {
                continue
            }

            let result = await requestAdminBootstrap(for: job)
            guard result.succeeded else {
                return .failed
            }

            didStartAny = true
            if !(await waitForSystemLaunchDaemon(job, timeoutSeconds: 15)) {
                return .failed
            }
        }

        return didStartAny ? .started : .alreadyRunning
    }

    static func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isProcessNamedRunning(name) {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    static func openAppBundle(at path: String) async -> Bool {
        let result = await ShellCommandRunner.run(
            "/usr/bin/open -n \(ShellCommandRunner.shellQuoted(path))"
        )
        return result.succeeded
    }

    private static func systemLaunchDaemonIsReady(_ job: SystemLaunchDaemonJob) async -> Bool {
        if let servicePort = job.servicePort {
            let result = await ShellCommandRunner.run(
                "/usr/sbin/lsof -nP -iTCP:\(servicePort) -sTCP:LISTEN >/dev/null 2>&1"
            )
            return result.exitCode == 0
        }

        let daemonLoaded = await ShellCommandRunner.run(
            "/bin/launchctl print system/\(ShellCommandRunner.shellQuoted(job.label)) >/dev/null 2>&1"
        )
        let processRunning = await ShellCommandRunner.run(
            "/usr/bin/pgrep -x \(ShellCommandRunner.shellQuoted(ShellCommandRunner.extendedRegexLiteral(job.processName))) >/dev/null 2>&1"
        )
        return daemonLoaded.exitCode == 0 && processRunning.exitCode == 0
    }

    private static func waitForSystemLaunchDaemon(
        _ job: SystemLaunchDaemonJob,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await systemLaunchDaemonIsReady(job) {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await systemLaunchDaemonIsReady(job)
    }

    private static func requestAdminBootstrap(for job: SystemLaunchDaemonJob) async -> ShellCommandResult {
        let quotedLabel = ShellCommandRunner.shellQuoted(job.label)
        let quotedPlist = ShellCommandRunner.shellQuoted(job.plistPath)
        let rootCommand = """
        if /bin/launchctl print system/\(quotedLabel) >/dev/null 2>&1; then /bin/launchctl kickstart -k system/\(quotedLabel); else /bin/launchctl bootstrap system \(quotedPlist); fi
        """
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(rootCommand)) with administrator privileges"
        return await ShellCommandRunner.run(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))"
        )
    }
}
