import AppKit
import Darwin
import Foundation
import Combine

@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var status: ProcessStatus = .idle
    @Published private(set) var snapshots: [WatchedAppSnapshot] = []
    @Published private(set) var processes: [AppProcess] = []
    @Published private(set) var hasLoadedProcessList = false
    @Published private(set) var message: String = "Idle."
    @Published private(set) var isWorking = false

    @Published var sortKey: ProcessSortKey = .cpu {
        didSet { resortProcesses() }
    }

    @Published private(set) var selectedPids: Set<Int32> = []

    var enableNotifications: Bool = true

    private var pollingTask: Task<Void, Never>?
    private var pollInterval: TimeInterval = 10
    private var pollProcessList = false

    private let currentPID = ProcessInfo.processInfo.processIdentifier

    deinit {
        pollingTask?.cancel()
    }

    func setPolling(interval: TimeInterval, includeProcessList: Bool) {
        pollInterval = max(2, interval)
        pollProcessList = includeProcessList
        restartPolling()
    }

    func restartPolling() {
        pollingTask?.cancel()
        pollInterval = max(2, pollInterval)
        let interval = pollInterval
        let includeList = pollProcessList
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                await self.refreshWatchedStatus(showMessage: false)
                if includeList, self.hasLoadedProcessList {
                    await self.loadProcessList(showMessage: false)
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func toggleSelection(_ pid: Int32) {
        guard pid != currentPID else { return }

        if selectedPids.contains(pid) {
            selectedPids.remove(pid)
        } else {
            selectedPids.insert(pid)
        }
    }

    func clearSelection() {
        selectedPids.removeAll()
    }

    func selectAll() {
        selectedPids = Set(processes.map { $0.pid }.filter { $0 != currentPID })
    }

    func batchTerminate(forceKill: Bool = false) async {
        let pids = selectedPids
        guard !pids.isEmpty else {
            message = "Nothing selected."
            return
        }
        await runAction {
            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            for pid in pids where pid != currentPID {
                Darwin.kill(pid, signal)
            }
            await settleAfterProcessChange()

            if !forceKill {
                for pid in pids where pid != currentPID && isProcessAlive(pid) {
                    Darwin.kill(pid, SIGKILL)
                }
                await settleAfterProcessChange()
            }

            let stopped = pids.filter { !isProcessAlive($0) }.count
            selectedPids.removeAll()
            message = "Stopped \(stopped) of \(pids.count) selected."
            await refreshAfterMutation()
        }
    }

    func refreshWatchedStatus(showMessage: Bool = true) async {
        await runAction {
            let watched = await currentSnapshots()
            apply(watched)

            if showMessage {
                message = watched.aggregateDetail
            }
        }
    }

    func refreshWatchedStatusUnchecked(showMessage: Bool = false) async {
        let watched = await currentSnapshots()
        apply(watched)
        if showMessage {
            message = watched.aggregateDetail
        }
    }

    func loadProcessList(showMessage: Bool = true) async {
        await runAction {
            async let snapshotsTask = currentSnapshots()
            async let runningTask = currentProcessList()

            let watched = await snapshotsTask
            let running = await runningTask

            apply(watched)
            processes = running
            hasLoadedProcessList = true
            resortProcesses()

            if showMessage {
                message = "Loaded \(running.count) processes."
            }
        }
    }

    func openApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let beforeOpen = await currentSnapshot(for: preset)
            let didOpen = beforeOpen.isMainRunning ? true : await openAppBundle(at: preset.appPath)
            if !beforeOpen.isMainRunning {
                _ = await bootstrapUserLaunchAgents(for: preset)
                await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: 3)
            }
            let daemonResult = await ensureSystemLaunchDaemons(for: preset)
            await refreshAfterMutation()

            let now = snapshot(for: preset)
            let daemonDetail = daemonResult.messageSuffix
            if now.isMainRunning {
                if daemonResult.didChangeState {
                    message = "Opening \(preset.displayName)\(daemonDetail)."
                } else {
                    message = "Opening \(preset.displayName)."
                }
            } else if daemonResult == .failed {
                message = "\(preset.displayName) service needs admin approval."
            } else {
                message = didOpen ? "Opening \(preset.displayName)." : "Could not open \(preset.displayName)."
            }
        }
    }

    func quitMainApp(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.isMainRunning ? await unloadUserLaunchAgents(for: preset) : false
            await terminateProcess(named: preset.mainProcessName, forceIfStillRunning: true)
            await settleAfterProcessChange()
            await refreshAfterMutation()

            if !before.isMainRunning && !snapshot(for: preset).isMainRunning {
                message = "No \(preset.displayName) app found."
            } else if !snapshot(for: preset).isMainRunning {
                message = unloadedAgents ? "\(preset.displayName) quit and launch agents unloaded." : "\(preset.displayName) quit."
            } else {
                message = "\(preset.displayName) may still run."
            }
        }
    }

    func quitHelpers(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.hasHelpers ? await unloadUserLaunchAgents(for: preset) : false
            for name in preset.helperProcessNames {
                await terminateProcess(named: name, forceIfStillRunning: true)
            }
            await settleAfterProcessChange()
            await refreshAfterMutation()

            let nowHelpers = snapshot(for: preset).helpersRunning
            if before.helpersRunning.isEmpty && nowHelpers.isEmpty {
                message = "No user helpers found."
            } else if nowHelpers.isEmpty {
                message = unloadedAgents ? "User helpers quit and launch agents unloaded." : "User helpers quit."
            } else {
                message = "User helpers may still run."
            }
        }
    }

    func quitAllKillable(_ preset: WatchedAppPreset) async {
        await runAction {
            let before = await currentSnapshot(for: preset)
            let unloadedAgents = before.hasAny ? await unloadUserLaunchAgents(for: preset) : false
            for name in preset.killableNames {
                await terminateProcess(named: name, forceIfStillRunning: true)
            }
            await settleAfterProcessChange()
            await refreshAfterMutation()

            let nowSnap = snapshot(for: preset)
            if !before.hasAny && !nowSnap.hasAny {
                message = "No watched processes found."
            } else if nowSnap.isMainRunning {
                message = "\(preset.displayName) may still run."
            } else if !nowSnap.helpersRunning.isEmpty {
                message = "User helpers may still run."
            } else {
                message = unloadedAgents ? "\(preset.displayName) closed and launch agents unloaded." : "\(preset.displayName) and helpers quit."
            }
        }
    }

    func terminate(_ process: AppProcess, forceKill: Bool = false) async {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return
        }

        await runAction {
            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            let result = Darwin.kill(process.pid, signal)
            await settleAfterProcessChange()

            if isProcessAlive(process.pid) {
                if forceKill {
                    message = "Could not stop \(process.name)."
                } else {
                    Darwin.kill(process.pid, SIGKILL)
                    await settleAfterProcessChange()

                    if isProcessAlive(process.pid) {
                        message = "Could not stop \(process.name)."
                    } else {
                        message = "\(process.name) force stopped."
                    }
                }
            } else if result == 0 {
                message = "\(process.name) stopped."
            } else {
                message = "Could not stop \(process.name)."
            }

            await refreshAfterMutation()
        }
    }

    func detail(for process: AppProcess) async -> ProcessDetail? {
        let result = await ShellCommandRunner.run(
            "/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(process.pid)"
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }

        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard tokens.count >= 8,
              let pid = Int32(tokens[0]),
              let ppid = Int32(tokens[1]) else {
            return nil
        }

        let user = tokens[2]
        let startTime = tokens[3..<8].joined(separator: " ")
        let command = tokens[8...].joined(separator: " ")

        return ProcessDetail(
            pid: pid,
            parentPID: ppid,
            user: user,
            startTime: startTime,
            command: command
        )
    }

    func isCurrentProcess(_ process: AppProcess) -> Bool {
        process.pid == currentPID
    }

    var ppidMap: [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for p in processes { map[p.pid] = p.parentPID }
        return map
    }

    private func refreshAfterMutation() async {
        if hasLoadedProcessList {
            async let snapshotsTask = currentSnapshots()
            async let runningTask = currentProcessList()

            let watched = await snapshotsTask
            let running = await runningTask

            apply(watched)
            processes = running
            resortProcesses()
        } else {
            let watched = await currentSnapshots()
            apply(watched)
        }
    }

    private func settleAfterProcessChange() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func terminateProcess(named name: String, forceIfStillRunning: Bool) async {
        _ = await ShellCommandRunner.run(
            "/usr/bin/pkill -TERM -x \(ShellCommandRunner.shellQuoted(name)) 2>/dev/null || true"
        )

        guard forceIfStillRunning else { return }

        await settleAfterProcessChange()
        if await isProcessNamedRunning(name) {
            _ = await ShellCommandRunner.run(
                "/usr/bin/pkill -KILL -x \(ShellCommandRunner.shellQuoted(name)) 2>/dev/null || true"
            )
        }
    }

    private func isProcessNamedRunning(_ name: String) async -> Bool {
        let result = await ShellCommandRunner.run(
            "/usr/bin/pgrep -x \(ShellCommandRunner.shellQuoted(name)) >/dev/null 2>&1"
        )
        return result.exitCode == 0
    }

    private func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> Bool {
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

    private func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> Bool {
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

    private enum LaunchDaemonEnsureResult: Equatable {
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

    private func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LaunchDaemonEnsureResult {
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

    private func systemLaunchDaemonIsReady(_ job: SystemLaunchDaemonJob) async -> Bool {
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
            "/usr/bin/pgrep -x \(ShellCommandRunner.shellQuoted(job.processName)) >/dev/null 2>&1"
        )
        return daemonLoaded.exitCode == 0 && processRunning.exitCode == 0
    }

    private func waitForSystemLaunchDaemon(_ job: SystemLaunchDaemonJob, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await systemLaunchDaemonIsReady(job) {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return await systemLaunchDaemonIsReady(job)
    }

    private func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isProcessNamedRunning(name) {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func openAppBundle(at path: String) async -> Bool {
        let result = await ShellCommandRunner.run(
            "/usr/bin/open -n \(ShellCommandRunner.shellQuoted(path))"
        )
        return result.succeeded
    }

    private func requestAdminBootstrap(for job: SystemLaunchDaemonJob) async -> ShellCommandResult {
        let rootCommand = """
        if /bin/launchctl print system/\(job.label) >/dev/null 2>&1; then /bin/launchctl kickstart -k system/\(job.label); else /bin/launchctl bootstrap system \(ShellCommandRunner.shellQuoted(job.plistPath)); fi
        """
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(rootCommand)) with administrator privileges"
        return await ShellCommandRunner.run(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))"
        )
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    private func snapshot(for preset: WatchedAppPreset) -> WatchedAppSnapshot {
        snapshots.first(where: { $0.preset.id == preset.id }) ?? WatchedAppSnapshot(preset: preset, runningNames: [])
    }

    private func currentSnapshots() async -> [WatchedAppSnapshot] {
        let presets = watchedAppsProvider?() ?? []
        var runningByPreset: [(WatchedAppPreset, Set<String>)] = []

        for preset in presets {
            var running = Set<String>()
            for name in preset.allProcessNames {
                let result = await ShellCommandRunner.run(
                    "/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(name))"
                )
                guard result.exitCode == 0 else { continue }
                if result.stdout.split(separator: "\n").contains(where: { line in
                    line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).count == 2
                }) {
                    running.insert(name)
                }
            }
            runningByPreset.append((preset, running))
        }

        return runningByPreset.map { WatchedAppSnapshot(preset: $0.0, runningNames: $0.1) }
    }

    private func currentSnapshot(for preset: WatchedAppPreset) async -> WatchedAppSnapshot {
        var running = Set<String>()
        for name in preset.allProcessNames {
            let result = await ShellCommandRunner.run(
                "/usr/bin/pgrep -x -l \(ShellCommandRunner.shellQuoted(name))"
            )
            guard result.exitCode == 0 else { continue }
            if result.stdout.split(separator: "\n").contains(where: { line in
                line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).count == 2
            }) {
                running.insert(name)
            }
        }
        return WatchedAppSnapshot(preset: preset, runningNames: running)
    }

    @Published var fetchExtendedStats: Bool = false

    private func currentProcessList() async -> [AppProcess] {
        let limit = processListLimitProvider?() ?? 80
        let command = "/bin/ps -arcwwwxo pid=,ppid=,pcpu=,rss=,etime=,comm= | /usr/bin/head -n \(limit)"
        let result = await ShellCommandRunner.run(command)

        guard result.succeeded else {
            return []
        }

        var parsed = result.stdout
            .split(separator: "\n")
            .compactMap(parseProcessLine)

        if fetchExtendedStats {
            let netStats = await currentNetworkStats()
            let diskStats = await currentDiskStats()
            for index in parsed.indices {
                parsed[index].netInKB = netStats[parsed[index].pid]?.0 ?? 0
                parsed[index].netOutKB = netStats[parsed[index].pid]?.1 ?? 0
                parsed[index].diskReadBlocks = diskStats[parsed[index].pid]?.0 ?? 0
                parsed[index].diskWriteBlocks = diskStats[parsed[index].pid]?.1 ?? 0
            }
        }
        return parsed
    }

    private func currentNetworkStats() async -> [Int32: (Double, Double)] {
        let result = await ShellCommandRunner.run(
            "/usr/bin/nettop -P -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null || true"
        )
        guard result.succeeded else { return [:] }
        var stats: [Int32: (Double, Double)] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let namePid = parts[0]
            guard let dotIndex = namePid.lastIndex(of: "."),
                  let pid = Int32(namePid[namePid.index(after: dotIndex)...]),
                  let inBytes = Double(parts[1]),
                  let outBytes = Double(parts[2]) else { continue }
            stats[pid] = (inBytes / 1024.0, outBytes / 1024.0)
        }
        return stats
    }

    private func currentDiskStats() async -> [Int32: (Double, Double)] {
        let result = await ShellCommandRunner.run(
            "/bin/ps -axo pid=,inblock=,oublock= 2>/dev/null || true"
        )
        guard result.succeeded else { return [:] }
        var stats: [Int32: (Double, Double)] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]),
                  let r = Double(parts[1]),
                  let w = Double(parts[2]) else { continue }
            stats[pid] = (r, w)
        }
        return stats
    }

    private func parseProcessLine(_ line: Substring) -> AppProcess? {
        let parts = line.split(
            separator: " ",
            maxSplits: 5,
            omittingEmptySubsequences: true
        )

        guard parts.count == 6,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let cpu = Double(parts[2]),
              let rssKB = Double(parts[3]) else {
            return nil
        }

        return AppProcess(
            pid: pid,
            parentPID: ppid,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            command: String(parts[5]),
            elapsedTime: String(parts[4]),
            netInKB: 0,
            netOutKB: 0,
            diskReadBlocks: 0,
            diskWriteBlocks: 0
        )
    }

    private func resortProcesses() {
        processes.sort { lhs, rhs in
            switch sortKey {
            case .cpu:
                if lhs.cpu == rhs.cpu {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.cpu > rhs.cpu
            case .memory:
                if lhs.memoryMB == rhs.memoryMB {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.memoryMB > rhs.memoryMB
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .pid:
                return lhs.pid < rhs.pid
            }
        }
    }

    private func apply(_ watched: [WatchedAppSnapshot]) {
        snapshots = watched
        status = watched.aggregateStatus

        if enableNotifications {
            let running = Set(watched.filter { $0.preset.notificationsEnabled }.flatMap { $0.runningNames })
            NotificationService.shared.diffAndNotify(currentRunningNames: running)
        }
    }

    private func runAction(_ operation: () async -> Void) async {
        guard !isWorking else {
            return
        }

        isWorking = true
        defer {
            isWorking = false
        }

        await operation()
    }

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
}

enum ShellCommandRunner {
    static func run(_ command: String) async -> ShellCommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let outputCapture = PipeCapture()
            let errorCapture = PipeCapture()

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardOutput = standardOutput
            process.standardError = standardError

            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData

                if !data.isEmpty {
                    outputCapture.append(data)
                }
            }

            standardError.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData

                if !data.isEmpty {
                    errorCapture.append(data)
                }
            }

            process.terminationHandler = { finishedProcess in
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil

                outputCapture.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
                errorCapture.append(standardError.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(
                    returning: ShellCommandResult(
                        command: command,
                        stdout: outputCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: errorCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        exitCode: finishedProcess.terminationStatus
                    )
                )
            }

            do {
                try process.run()
            } catch {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil

                continuation.resume(
                    returning: ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: error.localizedDescription,
                        exitCode: -1
                    )
                )
            }
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var string: String {
            lock.lock()
            defer {
                lock.unlock()
            }

            return String(data: data, encoding: .utf8) ?? ""
        }

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }
    }
}
