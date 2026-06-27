import Foundation

enum ProcessListReader {
    static func currentProcessList(limit: Int, fetchExtendedStats: Bool) async -> [AppProcess] {
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

    static func parseProcessLine(_ line: Substring) -> AppProcess? {
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

    private static func currentNetworkStats() async -> [Int32: (Double, Double)] {
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

    private static func currentDiskStats() async -> [Int32: (Double, Double)] {
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
}
