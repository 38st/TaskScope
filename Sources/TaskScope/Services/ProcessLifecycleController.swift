import Darwin
import Foundation

struct ProcessLifecycleRuntime: Sendable {
    var userID: uid_t
    var fileExists: @Sendable (String) -> Bool
    var runCommand: @Sendable (String, TimeInterval) async -> ShellCommandResult
    var loadProcessInventory: @Sendable () async -> Result<[AppProcess], ProcessInventoryError>
    var sleep: @Sendable (UInt64) async -> Void

    static let live = ProcessLifecycleRuntime(
        userID: getuid(),
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        runCommand: { command, timeout in
            await ShellCommandRunner.run(command, timeout: timeout)
        },
        loadProcessInventory: {
            await ProcessListReader.currentProcessList(fetchExtendedStats: false)
        },
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

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
    enum LaunchJobInspection: Equatable {
        case loaded
        case notLoaded
        case failed(String)
    }

    static func settleAfterProcessChange(
        runtime: ProcessLifecycleRuntime = .live
    ) async {
        await runtime.sleep(300_000_000)
    }

    static func terminateProcess(
        named name: String,
        forceIfStillRunning: Bool,
        runtime: ProcessLifecycleRuntime = .live
    ) async {
        guard case .success(let initialInventory) =
            await runtime.loadProcessInventory() else {
            return
        }

        let targets = matchingProcesses(named: name, in: initialInventory)
        for process in targets {
            _ = Darwin.kill(process.pid, SIGTERM)
        }

        guard forceIfStillRunning else { return }

        await settleAfterProcessChange(runtime: runtime)
        guard case .success(let refreshedInventory) =
            await runtime.loadProcessInventory() else {
            return
        }

        let originalIdentities = Set(targets.map(\.identity))
        for process in matchingProcesses(named: name, in: refreshedInventory)
            where originalIdentities.contains(process.identity) {
            _ = Darwin.kill(process.pid, SIGKILL)
        }
    }

    static func isProcessNamedRunning(
        _ name: String,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        guard case .success(let inventory) =
            await runtime.loadProcessInventory() else {
            return false
        }
        return !matchingProcesses(named: name, in: inventory).isEmpty
    }

    static func matchingProcesses(
        named name: String,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        inventory.filter { $0.name == name }
    }

    static func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []

        for job in jobs.reversed() {
            let target = "gui/\(uid)/\(job.label)"
            let plistExists = runtime.fileExists(job.plistPath)
            switch await inspectLaunchJob(target, runtime: runtime) {
            case .notLoaded:
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: plistExists ? .alreadyUnloaded : .missing,
                    detail: plistExists
                        ? "Already unloaded."
                        : "Missing plist at \(job.plistPath); job is not loaded."
                ))
                continue
            case .failed(let detail):
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not inspect job state: \(detail)"
                ))
                continue
            case .loaded:
                break
            }

            let command = "/bin/launchctl bootout \(ShellCommandRunner.shellQuoted(target))"
            let result = await runtime.runCommand(command, 15)
            let after = await inspectLaunchJob(target, runtime: runtime)
            let didUnload = after == .notLoaded
            results.append(LifecycleJobResult(
                label: job.label,
                state: result.succeeded && didUnload
                    ? (plistExists ? .changed : .missing)
                    : .failed,
                detail: result.succeeded && didUnload
                    ? (
                        plistExists
                            ? "Unloaded and verified."
                            : "Missing plist at \(job.plistPath); loaded job was still unloaded and verified."
                    )
                    : lifecycleInspectionFailure(
                        after,
                        commandResult: result,
                        fallback: "Job remained loaded."
                    )
            ))
        }

        await settleAfterProcessChange(runtime: runtime)
        return LifecycleBatchResult(jobs: results)
    }

    static func bootstrapUserLaunchAgents(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard runtime.fileExists(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .missing,
                    detail: "Missing plist at \(job.plistPath)."
                ))
                continue
            }

            let target = "gui/\(uid)/\(job.label)"
            switch await inspectLaunchJob(target, runtime: runtime) {
            case .loaded:
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyLoaded,
                    detail: "Already loaded."
                ))
                continue
            case .failed(let detail):
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not inspect job state: \(detail)"
                ))
                continue
            case .notLoaded:
                break
            }

            let bootstrap = await runtime.runCommand(
                "/bin/launchctl bootstrap \(ShellCommandRunner.shellQuoted("gui/\(uid)")) \(ShellCommandRunner.shellQuoted(job.plistPath))",
                15
            )
            guard bootstrap.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(bootstrap, fallback: "Bootstrap failed.")
                ))
                continue
            }

            _ = await runtime.runCommand(
                "/bin/launchctl enable \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            let kickstart = await runtime.runCommand(
                "/bin/launchctl kickstart -k \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            let verified = await inspectLaunchJob(target, runtime: runtime) == .loaded
            results.append(LifecycleJobResult(
                label: job.label,
                state: kickstart.succeeded && verified ? .changed : .failed,
                detail: kickstart.succeeded && verified
                    ? "Loaded and verified."
                    : commandFailure(kickstart, fallback: "Job could not be verified.")
            ))
        }

        await settleAfterProcessChange(runtime: runtime)
        return LifecycleBatchResult(jobs: results)
    }

    static func ensureSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleSystemLaunchDaemonJobs
        guard !jobs.isEmpty else { return .notNeeded }
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard runtime.fileExists(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .missing,
                    detail: "Missing plist at \(job.plistPath)."
                ))
                continue
            }

            if await systemLaunchDaemonIsReady(job, runtime: runtime) {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .verified,
                    detail: "Loaded process identity verified."
                ))
                continue
            }

            let result = await requestAdminBootstrap(for: job, runtime: runtime)
            guard result.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(result, fallback: "Administrator approval or bootstrap failed.")
                ))
                continue
            }

            let verified = await waitForSystemLaunchDaemon(
                job,
                timeoutSeconds: 15,
                runtime: runtime
            )
            results.append(LifecycleJobResult(
                label: job.label,
                state: verified ? .changed : .failed,
                detail: verified ? "Started and verified." : "Started but readiness could not be verified."
            ))
        }

        return LifecycleBatchResult(jobs: results)
    }

    static func waitForProcessNamed(
        _ name: String,
        timeoutSeconds: TimeInterval,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isProcessNamedRunning(name, runtime: runtime) {
                return true
            }
            await runtime.sleep(300_000_000)
        }
        return await isProcessNamedRunning(name, runtime: runtime)
    }

    static func openAppBundle(
        at path: String,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        guard runtime.fileExists(path) else { return false }
        let result = await runtime.runCommand(
            "/usr/bin/open -n \(ShellCommandRunner.shellQuoted(path))",
            15
        )
        return result.succeeded
    }

    private static func launchJobIsLoaded(
        _ target: String,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        await inspectLaunchJob(target, runtime: runtime) == .loaded
    }

    private static func inspectLaunchJob(
        _ target: String,
        runtime: ProcessLifecycleRuntime
    ) async -> LaunchJobInspection {
        let result = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))",
            15
        )
        return launchJobInspection(from: result)
    }

    static func launchJobInspection(from result: ShellCommandResult) -> LaunchJobInspection {
        if result.succeeded {
            return .loaded
        }

        let detail = [result.stderr, result.stdout]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = detail.lowercased()
        if result.exitCode == 113
            || normalized.contains("could not find service")
            || normalized.contains("service not found")
            || normalized.contains("no such process") {
            return .notLoaded
        }
        return .failed(detail.isEmpty ? "launchctl exited with status \(result.exitCode)." : detail)
    }

    private static func systemLaunchDaemonIsReady(
        _ job: SystemLaunchDaemonJob,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        let target = "system/\(job.label)"
        guard await launchJobIsLoaded(target, runtime: runtime),
              case .success(let inventory) =
                await runtime.loadProcessInventory() else {
            return false
        }
        let processes = matchingProcesses(named: job.processName, in: inventory)
        guard !processes.isEmpty else { return false }

        guard let servicePort = job.servicePort else { return true }
        let pidList = processes.map { String($0.pid) }.joined(separator: ",")
        let result = await runtime.runCommand(
            "/usr/sbin/lsof -nP -a -p \(ShellCommandRunner.shellQuoted(pidList)) -iTCP:\(servicePort) -sTCP:LISTEN",
            15
        )
        return result.succeeded
    }

    private static func waitForSystemLaunchDaemon(
        _ job: SystemLaunchDaemonJob,
        timeoutSeconds: TimeInterval,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await systemLaunchDaemonIsReady(job, runtime: runtime) {
                return true
            }
            await runtime.sleep(500_000_000)
        }
        return await systemLaunchDaemonIsReady(job, runtime: runtime)
    }

    private static func requestAdminBootstrap(
        for job: SystemLaunchDaemonJob,
        runtime: ProcessLifecycleRuntime
    ) async -> ShellCommandResult {
        let target = "system/\(job.label)"
        let rootCommand = """
        if /bin/launchctl print \(ShellCommandRunner.shellQuoted(target)) >/dev/null 2>&1; then
          /bin/launchctl kickstart -k \(ShellCommandRunner.shellQuoted(target))
        else
          /bin/launchctl bootstrap system \(ShellCommandRunner.shellQuoted(job.plistPath))
        fi
        """
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(rootCommand)) with administrator privileges"
        return await runtime.runCommand(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))",
            60
        )
    }

    private static func commandFailure(_ result: ShellCommandResult, fallback: String) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }

    private static func lifecycleInspectionFailure(
        _ inspection: LaunchJobInspection,
        commandResult: ShellCommandResult,
        fallback: String
    ) -> String {
        if case .failed(let detail) = inspection {
            return detail
        }
        return commandFailure(commandResult, fallback: fallback)
    }
}
