import Foundation

protocol ProcessDetailReading: Sendable {
    func readDetail(for process: AppProcess) async -> ProcessDetail?
}

struct SystemProcessDetailReader: ProcessDetailReading {
    func readDetail(for process: AppProcess) async -> ProcessDetail? {
        let result = await ShellCommandRunner.run(
            "/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(process.pid)"
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }

        let line = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 8,
              let pid = Int32(tokens[0]),
              let parentPID = Int32(tokens[1]) else {
            return nil
        }

        let startTime = tokens[3..<8].joined(separator: " ")
        // A PID can be reused between rendering the row and requesting details.
        // Both identities use `ps lstart`, so reject data from a new occupant.
        guard startTime == process.identity.startTime else { return nil }

        return ProcessDetail(
            pid: pid,
            parentPID: parentPID,
            user: tokens[2],
            startTime: startTime,
            command: tokens[8...].joined(separator: " ")
        )
    }
}
