import Darwin
import Foundation

enum ProcessInventoryError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "The process list command failed." : detail
        case .parseFailed:
            return "The process list could not be parsed."
        }
    }
}

protocol ProcessInventoryProviding: Sendable {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError>
}

struct SystemProcessInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        await ProcessListReader.currentProcessList(fetchExtendedStats: fetchExtendedStats)
    }
}

enum ProcessListReader {
    // `comm` supplies a useful display path when available. It remains argv-backed,
    // so lifecycle and destructive matching must use the separately resolved kernel
    // executable path rather than trusting this value.
    static let processListCommand = "/bin/ps -awwwxo pid=,ppid=,pcpu=,rss=,lstart=,etime=,comm="
    static let identityValidationCommand = "/bin/ps -awwwxo pid=,lstart="

    static func currentProcessList(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        let result = await ShellCommandRunner.run(processListCommand)

        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? "ps exited with status \(result.exitCode)." : result.stderr
            return .failure(.commandFailed(detail))
        }

        var parsed: [AppProcess]
        switch parseProcessListOutput(result.stdout) {
        case .success(let processes):
            parsed = processes
        case .failure(let error):
            return .failure(error)
        }

        let resolvedPaths = Dictionary(uniqueKeysWithValues: parsed.compactMap { process in
            executablePath(for: process.pid).map { (process.pid, $0) }
        })
        let validation = await ShellCommandRunner.run(identityValidationCommand)
        let validatedStartTimeMap: [Int32: String]
        switch validatedStartTimes(from: validation) {
        case .success(let startTimes):
            validatedStartTimeMap = startTimes
        case .failure(let error):
            return .failure(error)
        }
        // Process churn between the two `ps` snapshots is normal (the first
        // `ps` invocation can itself disappear). Keep only rows whose identity
        // survived unchanged; malformed validation output still fails the
        // entire read, but a cleanly missing PID is simply no longer present.
        parsed = validatedProcesses(parsed, using: validatedStartTimeMap)
        attachExecutablePaths(
            to: &parsed,
            resolvedPaths: resolvedPaths,
            validatedStartTimes: validatedStartTimeMap
        )

        if fetchExtendedStats {
            let netStats = await currentNetworkStats()
            let diskStats = await currentDiskStats()
            for index in parsed.indices {
                parsed[index].netInKB = netStats?[parsed[index].pid]?.0
                parsed[index].netOutKB = netStats?[parsed[index].pid]?.1
                parsed[index].diskReadBlocks = diskStats?[parsed[index].pid]?.0
                parsed[index].diskWriteBlocks = diskStats?[parsed[index].pid]?.1
            }
        }

        return .success(parsed)
    }

    static func parseProcessListOutput(
        _ output: String
    ) -> Result<[AppProcess], ProcessInventoryError> {
        var processes: [AppProcess] = []
        for line in output.split(separator: "\n") {
            guard let process = parseProcessLine(line) else {
                return .failure(.parseFailed)
            }
            processes.append(process)
        }
        return .success(processes)
    }

    static func parseProcessLine(_ line: Substring) -> AppProcess? {
        let extendedParts = line.split(
            separator: " ",
            maxSplits: 10,
            omittingEmptySubsequences: true
        )

        if extendedParts.count == 11,
           let pid = Int32(extendedParts[0]),
           let ppid = Int32(extendedParts[1]),
           let cpu = Double(extendedParts[2]),
           let rssKB = Double(extendedParts[3]) {
            return AppProcess(
                pid: pid,
                parentPID: ppid,
                cpu: cpu,
                memoryMB: rssKB / 1024.0,
                command: String(extendedParts[10]),
                elapsedTime: String(extendedParts[9]),
                startTime: extendedParts[4...8].joined(separator: " "),
                netInKB: nil,
                netOutKB: nil,
                diskReadBlocks: nil,
                diskWriteBlocks: nil
            )
        }

        let legacyParts = line.split(
            separator: " ",
            maxSplits: 5,
            omittingEmptySubsequences: true
        )

        guard legacyParts.count == 6,
              let pid = Int32(legacyParts[0]),
              let ppid = Int32(legacyParts[1]),
              let cpu = Double(legacyParts[2]),
              let rssKB = Double(legacyParts[3]) else {
            return nil
        }

        return AppProcess(
            pid: pid,
            parentPID: ppid,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            command: String(legacyParts[5]),
            elapsedTime: String(legacyParts[4]),
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }

    static func attachExecutablePaths(
        to processes: inout [AppProcess],
        resolvedPaths: [Int32: String],
        validatedStartTimes: [Int32: String]
    ) {
        for index in processes.indices {
            let process = processes[index]
            guard validatedStartTimes[process.pid] == process.startTime,
                  let path = resolvedPaths[process.pid],
                  path.hasPrefix("/") else {
                processes[index].executablePath = nil
                continue
            }
            processes[index].executablePath = URL(fileURLWithPath: path)
                .standardizedFileURL.path
        }
    }

    static func parseStartTimes(
        _ output: String
    ) -> Result<[Int32: String], ProcessInventoryError> {
        var values: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(
                separator: " ",
                maxSplits: 5,
                omittingEmptySubsequences: true
            )
            guard parts.count == 6, let pid = Int32(parts[0]) else {
                return .failure(.parseFailed)
            }
            values[pid] = parts[1...5].joined(separator: " ")
        }
        return .success(values)
    }

    static func validatedStartTimes(
        from result: ShellCommandResult
    ) -> Result<[Int32: String], ProcessInventoryError> {
        guard result.succeeded else {
            let detail = result.stderr.isEmpty
                ? "Identity validation exited with status \(result.exitCode)."
                : result.stderr
            return .failure(.commandFailed(detail))
        }

        switch parseStartTimes(result.stdout) {
        case .success(let startTimes):
            return .success(startTimes)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func validatedProcesses(
        _ processes: [AppProcess],
        using startTimes: [Int32: String]
    ) -> [AppProcess] {
        processes.filter { startTimes[$0.pid] == $0.startTime }
    }

    static func executablePath(for pid: Int32) -> String? {
        // Swift cannot import the arithmetic C macro
        // `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`) directly.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func currentNetworkStats() async -> [Int32: (Double, Double)]? {
        let result = await ShellCommandRunner.run(
            "/usr/bin/nettop -P -L 1 -n -x -J bytes_in,bytes_out"
        )
        guard result.succeeded else { return nil }
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
        return stats.isEmpty ? nil : stats
    }

    private static func currentDiskStats() async -> [Int32: (Double, Double)]? {
        let result = await ShellCommandRunner.run(
            "/bin/ps -axo pid=,inblock=,oublock="
        )
        guard result.succeeded else { return nil }
        var stats: [Int32: (Double, Double)] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]),
                  let r = Double(parts[1]),
                  let w = Double(parts[2]) else { continue }
            stats[pid] = (r, w)
        }
        return stats.isEmpty ? nil : stats
    }
}
