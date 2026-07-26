import Darwin
import Foundation

enum LifecycleJobState: String, Equatable, Sendable {
    case missing
    case alreadyLoaded
    case alreadyUnloaded
    case changed
    case failed
    case verified
}

struct LifecycleJobResult: Equatable, Sendable {
    var label: String
    var state: LifecycleJobState
    var detail: String

    var succeeded: Bool {
        ![.missing, .failed].contains(state)
    }
}

struct LifecycleBatchResult: Equatable, Sendable {
    var jobs: [LifecycleJobResult]

    static let notNeeded = LifecycleBatchResult(jobs: [])

    var succeeded: Bool {
        jobs.allSatisfy(\.succeeded)
    }

    var didChangeState: Bool {
        jobs.contains { $0.state == .changed }
    }

    var failureSummary: String? {
        let failures = jobs.filter { !$0.succeeded }
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.label): \($0.detail)" }.joined(separator: "; ")
    }
}

struct LifecycleReport: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var jobs: [LifecycleJobResult]
}

protocol ProcessLifecycleServicing: Sendable {
    func appBundleExists(at path: String) -> Bool
    func settleAfterProcessChange() async
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async
    func isProcessNamedRunning(_ name: String) async -> Bool
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool
    func openAppBundle(at path: String) async -> Bool
}

struct SystemProcessLifecycleService: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange()
    }

    func terminateProcess(named name: String, forceIfStillRunning: Bool) async {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            forceIfStillRunning: forceIfStillRunning
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset)
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset)
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(name, timeoutSeconds: timeoutSeconds)
    }

    func openAppBundle(at path: String) async -> Bool {
        await ProcessLifecycleController.openAppBundle(at: path)
    }
}

enum ProcessLifecycleController {
    static func settleAfterProcessChange() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static func terminateProcess(named name: String, forceIfStillRunning: Bool) async {
        let literalName = ShellCommandRunner.extendedRegexLiteral(name)
        _ = await ShellCommandRunner.run(
            "/usr/bin/pkill -TERM -x \(ShellCommandRunner.shellQuoted(literalName))"
        )

        guard forceIfStillRunning else { return }

        await settleAfterProcessChange()
        if await isProcessNamedRunning(name) {
            _ = await ShellCommandRunner.run(
                "/usr/bin/pkill -KILL -x \(ShellCommandRunner.shellQuoted(literalName))"
            )
        }
    }

    static func isProcessNamedRunning(_ name: String) async -> Bool {
        let literalName = ShellCommandRunner.extendedRegexLiteral(name)
        let result = await ShellCommandRunner.run(
            "/usr/bin/pgrep -x \(ShellCommandRunner.shellQuoted(literalName))"
        )
        return result.exitCode == 0
    }

    static func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = getuid()
        var results: [LifecycleJobResult] = []

        for job in jobs.reversed() {
            let target = "gui/\(uid)/\(job.label)"
            guard await launchJobIsLoaded(target) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyUnloaded,
                    detail: "Already unloaded."
                ))
                continue
            }

            let command = "/bin/launchctl bootout \(ShellCommandRunner.shellQuoted(target))"
            let result = await ShellCommandRunner.run(command)
            let stillLoaded = await launchJobIsLoaded(target)
            results.append(LifecycleJobResult(
                label: job.label,
                state: result.succeeded && !stillLoaded ? .changed : .failed,
                detail: result.succeeded && !stillLoaded
                    ? "Unloaded and verified."
                    : commandFailure(result, fallback: "Job remained loaded.")
            ))
        }

        await settleAfterProcessChange()
        return LifecycleBatchResult(jobs: results)
    }

    static func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = getuid()
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard FileManager.default.fileExists(atPath: job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .missing,
                    detail: "Missing plist at \(job.plistPath)."
                ))
                continue
            }

            let target = "gui/\(uid)/\(job.label)"
            if await launchJobIsLoaded(target) {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyLoaded,
                    detail: "Already loaded."
                ))
                continue
            }

            let bootstrap = await ShellCommandRunner.run(
                "/bin/launchctl bootstrap \(ShellCommandRunner.shellQuoted("gui/\(uid)")) \(ShellCommandRunner.shellQuoted(job.plistPath))"
            )
            guard bootstrap.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(bootstrap, fallback: "Bootstrap failed.")
                ))
                continue
            }

            _ = await ShellCommandRunner.run(
                "/bin/launchctl enable \(ShellCommandRunner.shellQuoted(target))"
            )
            let kickstart = await ShellCommandRunner.run(
                "/bin/launchctl kickstart -k \(ShellCommandRunner.shellQuoted(target))"
            )
            let verified = await launchJobIsLoaded(target)
            results.append(LifecycleJobResult(
                label: job.label,
                state: kickstart.succeeded && verified ? .changed : .failed,
                detail: kickstart.succeeded && verified
                    ? "Loaded and verified."
                    : commandFailure(kickstart, fallback: "Job could not be verified.")
            ))
        }

        await settleAfterProcessChange()
        return LifecycleBatchResult(jobs: results)
    }

    static func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleSystemLaunchDaemonJobs
        guard !jobs.isEmpty else { return .notNeeded }
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard FileManager.default.fileExists(atPath: job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .missing,
                    detail: "Missing plist at \(job.plistPath)."
                ))
                continue
            }

            if await systemLaunchDaemonIsReady(job) {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .verified,
                    detail: "Loaded process identity verified."
                ))
                continue
            }

            let result = await requestAdminBootstrap(for: job)
            guard result.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(result, fallback: "Administrator approval or bootstrap failed.")
                ))
                continue
            }

            let verified = await waitForSystemLaunchDaemon(job, timeoutSeconds: 15)
            results.append(LifecycleJobResult(
                label: job.label,
                state: verified ? .changed : .failed,
                detail: verified ? "Started and verified." : "Started but readiness could not be verified."
            ))
        }

        return LifecycleBatchResult(jobs: results)
    }

    static func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isProcessNamedRunning(name) {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return await isProcessNamedRunning(name)
    }

    static func openAppBundle(at path: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let result = await ShellCommandRunner.run(
            "/usr/bin/open -n \(ShellCommandRunner.shellQuoted(path))"
        )
        return result.succeeded
    }

    private static func launchJobIsLoaded(_ target: String) async -> Bool {
        let result = await ShellCommandRunner.run(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))"
        )
        return result.succeeded
    }

    private static func systemLaunchDaemonIsReady(_ job: SystemLaunchDaemonJob) async -> Bool {
        let target = "system/\(job.label)"
        guard await launchJobIsLoaded(target),
              await isProcessNamedRunning(job.processName) else {
            return false
        }

        guard let servicePort = job.servicePort else { return true }
        let result = await ShellCommandRunner.run(
            "/usr/sbin/lsof -nP -a -c \(ShellCommandRunner.shellQuoted(job.processName)) -iTCP:\(servicePort) -sTCP:LISTEN"
        )
        return result.succeeded
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
        let target = "system/\(job.label)"
        let rootCommand = """
        if /bin/launchctl print \(ShellCommandRunner.shellQuoted(target)) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k \(ShellCommandRunner.shellQuoted(target))
        else
          /bin/launchctl bootstrap system \(ShellCommandRunner.shellQuoted(job.plistPath))
        fi
        """
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(rootCommand)) with administrator privileges"
        return await ShellCommandRunner.run(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))",
            timeout: 60
        )
    }

    private static func commandFailure(_ result: ShellCommandResult, fallback: String) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }
}
