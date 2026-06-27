import Foundation

enum PresetInputParser {
    static func list(from value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func userLaunchAgentJobs(labels: String, paths: String) -> [UserLaunchAgentJob] {
        let labelList = list(from: labels)
        let pathList = list(from: paths)
        guard !labelList.isEmpty else { return [] }

        return zip(labelList, pathList).map {
            UserLaunchAgentJob(label: $0, plistPath: $1)
        }
    }

    static func systemLaunchDaemonJobs(
        labels: String,
        paths: String,
        processNames: String,
        ports: String
    ) -> [SystemLaunchDaemonJob] {
        let labelList = list(from: labels)
        let pathList = list(from: paths)
        let nameList = list(from: processNames)
        let portList = list(from: ports).compactMap { Int($0) }
        guard !labelList.isEmpty else { return [] }

        return zip(labelList, pathList).enumerated().map { index, pair in
            SystemLaunchDaemonJob(
                label: pair.0,
                plistPath: pair.1,
                processName: index < nameList.count ? nameList[index] : pair.0,
                servicePort: index < portList.count ? portList[index] : nil
            )
        }
    }
}
