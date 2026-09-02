import Foundation

protocol ProcessDetailReading: Sendable {
    func readDetail(for process: AppProcess) async -> ProcessDetail?
}

struct SystemProcessDetailReader: ProcessDetailReading {
    static let detailColumnCount = 8

    func readDetail(for process: AppProcess) async -> ProcessDetail? {
        let result = await ShellCommandRunner.run(
            "/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(process.pid)"
        )
        guard result.succeeded, !result.stdout.isEmpty else { return nil }

        let line = result.stdout
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return Self.parseDetailLine(line, expectedStartTime: process.identity.startTime)
    }

    /// `pid ppid user lstart(5) comm`. The command is the raw text after the
    /// eighth whitespace-separated field so internal runs of spaces survive
    /// instead of being collapsed by a re-join.
    static func parseDetailLine(_ line: String, expectedStartTime: String) -> ProcessDetail? {
        guard let (tokens, remainder) = leadingFields(in: line, count: detailColumnCount),
              let pid = Int32(tokens[0]),
              let parentPID = Int32(tokens[1]) else {
            return nil
        }

        let startTime = tokens[3..<8].joined(separator: " ")
        // A PID can be reused between rendering the row and requesting details.
        // Both identities use `ps lstart`, so reject data from a new occupant.
        guard startTime == expectedStartTime else { return nil }

        return ProcessDetail(
            pid: pid,
            parentPID: parentPID,
            user: tokens[2],
            startTime: startTime,
            command: remainder
        )
    }

    /// Splits off `count` whitespace-separated fields and returns the untouched
    /// remainder (leading separator run removed, internal spaces preserved).
    private static func leadingFields(in line: String, count: Int) -> ([String], String)? {
        var tokens: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex, tokens.count < count {
            let character = line[index]
            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if tokens.count < count, !current.isEmpty {
            tokens.append(current)
            current = ""
        }
        guard tokens.count == count else { return nil }
        var remainderStart = index
        while remainderStart < line.endIndex,
              line[remainderStart] == " " || line[remainderStart] == "\t" {
            remainderStart = line.index(after: remainderStart)
        }
        let remainder = String(line[remainderStart...])
            .trimmingCharacters(in: .newlines)
        return (tokens, remainder)
    }
}
