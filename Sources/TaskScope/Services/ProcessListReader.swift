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
    static func currentProcessList(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        let command = "/bin/ps -acwwwxo pid=,ppid=,pcpu=,rss=,lstart=,etime=,comm="
        let result = await ShellCommandRunner.run(command)

        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? "ps exited with status \(result.exitCode)." : result.stderr
            return .failure(.commandFailed(detail))
        }

        var parsed = result.stdout
            .split(separator: "\n")
            .compactMap(parseProcessLine)

        guard result.stdout.isEmpty || !parsed.isEmpty else {
            return .failure(.parseFailed)
        }

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
