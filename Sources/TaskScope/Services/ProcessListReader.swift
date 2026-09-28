import Darwin
import Foundation

enum ProcessInventoryError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(String)
    case parseFailed
    /// The read was cancelled by its caller (a poll restart, a view teardown).
    /// It says nothing about the inventory and is never recorded as a load
    /// failure.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "The process list command failed." : detail
        case .parseFailed:
            return "The process list could not be parsed."
        case .cancelled:
            return "The process list read was cancelled."
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
    //
    // Column layout (12 whitespace-separated tokens; `lstart` is 5):
    //   pid ppid uid pcpu rss lstart(5) etime comm
    // Every command runs with LC_ALL=C (see ShellCommandRunner), so decimals use
    // "." and `lstart` keeps the C-locale shape.
    static let processListCommand = "/bin/ps -awwwxo pid=,ppid=,uid=,pcpu=,rss=,lstart=,etime=,comm="
    static let identityValidationCommand = "/bin/ps -awwwxo pid=,lstart="

    static func currentProcessList(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        let result = await ShellCommandRunner.run(processListCommand)
        if let cancellation = cancellation(of: result) {
            return .failure(cancellation)
        }
        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? "ps \(result.failureDescription)." : result.stderr
            return .failure(.commandFailed(detail))
        }

        var parsed: [AppProcess]
        switch parseProcessListOutput(result.stdout) {
        case .success(let processes):
            parsed = processes
        case .failure(let error):
            return .failure(error)
        }

        let resolvedPaths = Dictionary(
            parsed.compactMap { process in
                executablePath(for: process.pid).map { (process.pid, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let validation = await ShellCommandRunner.run(identityValidationCommand)
        if let cancellation = cancellation(of: validation) {
            return .failure(cancellation)
        }
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
        // This process must survive both snapshots. A nonempty but incomplete
        // validation result must not turn a broken read into "nothing running".
        guard parsed.contains(where: { $0.pid == ProcessInfo.processInfo.processIdentifier }) else {
            return .failure(.parseFailed)
        }
        attachExecutablePaths(
            to: &parsed,
            resolvedPaths: resolvedPaths,
            validatedStartTimes: validatedStartTimeMap
        )

        if fetchExtendedStats {
            let netStats = await currentNetworkStats()
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            for index in parsed.indices {
                parsed[index].netInKB = netStats?[parsed[index].pid]?.0
                parsed[index].netOutKB = netStats?[parsed[index].pid]?.1
                let disk = diskIOBytes(for: parsed[index].pid)
                parsed[index].diskReadBytes = disk?.read
                parsed[index].diskWriteBytes = disk?.written
            }
        }

        return .success(parsed)
    }

    /// A cancelled command (or a cancelled calling task) is reported as
    /// `.cancelled` so callers never record it as an inventory fault.
    static func cancellation(of result: ShellCommandResult) -> ProcessInventoryError? {
        if Task.isCancelled || result.exitCode == ShellCommandRunner.cancelledExitCode {
            return .cancelled
        }
        return nil
    }

    /// Rows that cannot be parsed, or that name a pid TaskScope must never
    /// signal, are dropped while the rest of the inventory is kept. Output with
    /// no usable rows, or a repeated pid (an inconsistent snapshot), fails the
    /// whole read.
    static func parseProcessListOutput(
        _ output: String
    ) -> Result<[AppProcess], ProcessInventoryError> {
        var processes: [AppProcess] = []
        var seenPIDs: Set<Int32> = []
        for line in output.split(separator: "\n") {
            guard let process = parseProcessLine(line) else {
                continue
            }
            guard seenPIDs.insert(process.pid).inserted else {
                return .failure(.parseFailed)
            }
            processes.append(process)
        }
        guard !processes.isEmpty else {
            return .failure(.parseFailed)
        }
        return .success(processes)
    }

    /// Parses one `processListCommand` row. Exactly 11 tokens is a row whose
    /// `comm` is empty; anything else that does not fit the 12-token shape is
    /// rejected so the caller can drop that row.
    static func parseProcessLine(_ line: Substring) -> AppProcess? {
        let parts = line.split(
            separator: " ",
            maxSplits: 11,
            omittingEmptySubsequences: true
        )
        guard parts.count == 11 || parts.count == 12,
              let pid = Int32(parts[0]),
              ProcessSignalGuard.isSignalablePID(pid),
              let ppid = Int32(parts[1]),
              let uid = uid_t(parts[2]),
              let cpu = decimal(parts[3]),
              let rssKB = decimal(parts[4]) else {
            return nil
        }

        return AppProcess(
            pid: pid,
            parentPID: ppid,
            uid: uid,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            command: parts.count == 12
                ? String(parts[11]).trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            elapsedTime: String(parts[10]),
            startTime: parts[5...9].joined(separator: " "),
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    /// Accepts "0.5" and, defensively, "0,5": the command runs under LC_ALL=C,
    /// but a comma decimal must still parse rather than drop the row.
    private static func decimal(_ token: Substring) -> Double? {
        Double(token) ?? Double(token.replacingOccurrences(of: ",", with: "."))
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
            // ps pads the final lstart column. A bounded split left those
            // trailing spaces attached to the year, making every identity
            // comparison fail except an accidentally trimmed final row.
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 6, let pid = Int32(parts[0]) else {
                return .failure(.parseFailed)
            }
            guard values.updateValue(parts[1...5].joined(separator: " "), forKey: pid) == nil else {
                return .failure(.parseFailed)
            }
        }
        return .success(values)
    }

    static func validatedStartTimes(
        from result: ShellCommandResult
    ) -> Result<[Int32: String], ProcessInventoryError> {
        guard result.succeeded else {
            let detail = result.stderr.isEmpty
                ? "Identity validation \(result.failureDescription)."
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

    /// Cumulative disk I/O from the kernel's resource-usage record. `ps`'s
    /// `inblock`/`oublock` columns print `-` for every row on current macOS, so
    /// they were never a source of data. The kernel refuses this call for
    /// processes the caller may not inspect; those rows stay nil.
    static func diskIOBytes(for pid: Int32) -> (read: Double, written: Double)? {
        // `rusage_info_t` is `void *`; the C API is declared as taking a pointer
        // to it but writes the struct at the pointed-to address itself, exactly
        // as its callers pass `(rusage_info_t *)&info`.
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { infoPointer -> Int32 in
            infoPointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
        }
        guard status == 0 else { return nil }
        return (Double(info.ri_diskio_bytesread), Double(info.ri_diskio_byteswritten))
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
}
