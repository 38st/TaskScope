import Foundation

enum ProcessLifecycleController {
    enum LaunchJobInspection: Equatable {
        case loaded
        case notLoaded
        case failed(String)
    }

    static func settleAfterProcessChange(
        runtime: ProcessLifecycleRuntime = .live
    ) async {
        await ProcessTerminationController.settle(runtime: runtime)
    }

    @discardableResult
    static func terminateProcess(
        named name: String,
        forceIfStillRunning: Bool,
        expectedExecutableDirectory: String? = nil,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> ProcessTerminationOutcome {
        await ProcessTerminationController.terminate(
            named: name,
            policy: forceIfStillRunning ? .gracefulThenForce : .graceful,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            runtime: runtime
        )
    }

    @discardableResult
    static func terminateProcess(
        named name: String,
        policy: TerminationPolicy,
        expectedExecutableDirectory: String? = nil,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> ProcessTerminationOutcome {
        await ProcessTerminationController.terminate(
            named: name,
            policy: policy,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            runtime: runtime
        )
    }

    static func isProcessNamedRunning(
        _ name: String,
        expectedExecutableDirectory: String? = nil,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        await ProcessTerminationController.isRunning(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            runtime: runtime
        )
    }

    static func matchingProcesses(
        named name: String,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        ProcessTerminationController.matchingProcesses(named: name, in: inventory)
    }

    static func terminationTargets(
        named name: String,
        expectedExecutableDirectory: String?,
        excludingPID: Int32,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        ProcessTerminationController.terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: excludingPID,
            in: inventory
        )
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
                // An absent plist is not a failure when the goal is to *stop* the
                // job: there is nothing loaded and nothing to unload, so the stop
                // succeeded. `.missing` is reserved for the bootstrap paths, where
                // an absent plist genuinely prevents the requested action.
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyUnloaded,
                    detail: plistExists
                        ? "Already unloaded."
                        : "No plist at \(job.plistPath); job is not loaded."
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
                    ? .changed
                    : .failed,
                detail: result.succeeded && didUnload
                    ? (
                        plistExists
                            ? "Unloaded and verified."
                            : "No plist at \(job.plistPath); loaded job was still unloaded and verified."
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
            guard let plistLabel = runtime.launchAgentLabel(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not read a valid Label from \(job.plistPath)."
                ))
                continue
            }
            guard plistLabel == job.label else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Configured label does not match plist Label \(plistLabel)."
                ))
                continue
            }

            let target = "gui/\(uid)/\(job.label)"
            var wasAlreadyLoaded = false
            switch await inspectLaunchJob(target, runtime: runtime) {
            case .loaded:
                wasAlreadyLoaded = true
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

            if !wasAlreadyLoaded {
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
            }

            let enable = await runtime.runCommand(
                "/bin/launchctl enable \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            guard enable.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(enable, fallback: "Loaded, but enable failed.")
                ))
                continue
            }
            let kickstart = await runtime.runCommand(
                "/bin/launchctl kickstart -k \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            let verified = await inspectLaunchJob(target, runtime: runtime) == .loaded
            results.append(LifecycleJobResult(
                label: job.label,
                state: kickstart.succeeded && verified ? .changed : .failed,
                detail: kickstart.succeeded && verified
                    ? (wasAlreadyLoaded ? "Re-enabled, restarted, and verified." : "Loaded and verified.")
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
        guard preset.hasCanonicalGlobalProtectIdentity else { return .notNeeded }
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
        expectedExecutableDirectory: String? = nil,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        await ProcessTerminationController.waitUntilRunning(
            named: name,
            timeoutSeconds: timeoutSeconds,
            expectedExecutableDirectory: expectedExecutableDirectory,
            runtime: runtime
        )
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
        let inspection = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))",
            15
        )
        guard let jobPID = launchJobPID(from: inspection),
              case .success(let inventory) = await runtime.loadProcessInventory(),
              let process = inventory.first(where: {
                  $0.pid == jobPID && $0.name == job.processName
              }) else {
            return false
        }

        guard let servicePort = job.servicePort else { return true }
        let result = await runtime.runCommand(
            "/usr/sbin/lsof -nP -a -p \(ShellCommandRunner.shellQuoted(String(process.pid))) -iTCP:\(servicePort) -sTCP:LISTEN",
            15
        )
        return result.succeeded
    }

    static func launchJobPID(from result: ShellCommandResult) -> Int32? {
        guard result.succeeded else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "pid",
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0 else {
                continue
            }
            return pid
        }
        return nil
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
