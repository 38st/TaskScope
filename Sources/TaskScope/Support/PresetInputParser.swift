import Foundation

enum PresetInputParser {
    struct ParseResult<Value> {
        var value: Value
        var errors: [String]

        var isValid: Bool { errors.isEmpty }
    }

    static func list(from value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func userLaunchAgentJobs(labels: String, paths: String) -> [UserLaunchAgentJob] {
        parseUserLaunchAgentJobs(labels: labels, paths: paths).value
    }

    static func parseUserLaunchAgentJobs(
        labels: String,
        paths: String
    ) -> ParseResult<[UserLaunchAgentJob]> {
        let labelList = list(from: labels)
        let pathList = list(from: paths)
        guard !labelList.isEmpty || !pathList.isEmpty else {
            return ParseResult(value: [], errors: [])
        }
        guard labelList.count == pathList.count else {
            return ParseResult(
                value: [],
                errors: ["Launch-agent labels and plist paths must have the same item count."]
            )
        }

        return ParseResult(
            value: zip(labelList, pathList).map {
                UserLaunchAgentJob(label: $0, plistPath: $1)
            },
            errors: []
        )
    }

    static func systemLaunchDaemonJobs(
        labels: String,
        paths: String,
        processNames: String,
        ports: String
    ) -> [SystemLaunchDaemonJob] {
        parseSystemLaunchDaemonJobs(
            labels: labels,
            paths: paths,
            processNames: processNames,
            ports: ports
        ).value
    }

    static func parseSystemLaunchDaemonJobs(
        labels: String,
        paths: String,
        processNames: String,
        ports: String
    ) -> ParseResult<[SystemLaunchDaemonJob]> {
        let labelList = list(from: labels)
        let pathList = list(from: paths)
        let nameList = positionalList(from: processNames)
        let portTokens = positionalList(from: ports)
        guard !labelList.isEmpty || !pathList.isEmpty || !nameList.isEmpty || !portTokens.isEmpty else {
            return ParseResult(value: [], errors: [])
        }

        var errors: [String] = []
        if labelList.count != pathList.count {
            errors.append("Daemon labels and plist paths must have the same item count.")
        }
        if nameList.count > labelList.count {
            errors.append("Daemon process names contain more items than daemon labels.")
        }
        if portTokens.count > labelList.count {
            errors.append("Daemon ports contain more items than daemon labels.")
        }

        let portList: [Int?] = portTokens.enumerated().map { index, token in
            guard !token.isEmpty else { return nil }
            guard let port = Int(token), (1...65_535).contains(port) else {
                errors.append("Daemon port item \(index + 1) is invalid: \(token).")
                return nil
            }
            return port
        }
        guard errors.isEmpty else {
            return ParseResult(value: [], errors: errors)
        }

        return ParseResult(
            value: zip(labelList, pathList).enumerated().map { index, pair in
                let positionalName = index < nameList.count ? nameList[index] : ""
                return SystemLaunchDaemonJob(
                    label: pair.0,
                    plistPath: pair.1,
                    processName: positionalName.isEmpty ? pair.0 : positionalName,
                    servicePort: index < portList.count ? portList[index] : nil
                )
            },
            errors: []
        )
    }

    private static func positionalList(from value: String) -> [String] {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
