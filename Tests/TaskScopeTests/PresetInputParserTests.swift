import XCTest
@testable import TaskScope

final class PresetInputParserTests: XCTestCase {
    func testListTrimsWhitespaceAndDropsEmptyItems() {
        XCTAssertEqual(
            PresetInputParser.list(from: " GlobalProtect, PanGPA, , PanGPS "),
            ["GlobalProtect", "PanGPA", "PanGPS"]
        )
    }

    func testUserLaunchAgentJobsPairLabelsAndPaths() {
        let jobs = PresetInputParser.userLaunchAgentJobs(
            labels: "com.example.agent, com.example.second",
            paths: "/Library/LaunchAgents/com.example.agent.plist, /Library/LaunchAgents/com.example.second.plist"
        )

        XCTAssertEqual(jobs, [
            UserLaunchAgentJob(
                label: "com.example.agent",
                plistPath: "/Library/LaunchAgents/com.example.agent.plist"
            ),
            UserLaunchAgentJob(
                label: "com.example.second",
                plistPath: "/Library/LaunchAgents/com.example.second.plist"
            )
        ])
    }

    func testSystemLaunchDaemonJobsUseFallbackProcessNameAndOptionalPort() {
        let jobs = PresetInputParser.systemLaunchDaemonJobs(
            labels: "com.example.daemon, com.example.other",
            paths: "/Library/LaunchDaemons/com.example.daemon.plist, /Library/LaunchDaemons/com.example.other.plist",
            processNames: "ExampleDaemon",
            ports: "1234, not-a-port"
        )

        XCTAssertEqual(jobs, [
            SystemLaunchDaemonJob(
                label: "com.example.daemon",
                plistPath: "/Library/LaunchDaemons/com.example.daemon.plist",
                processName: "ExampleDaemon",
                servicePort: 1234
            ),
            SystemLaunchDaemonJob(
                label: "com.example.other",
                plistPath: "/Library/LaunchDaemons/com.example.other.plist",
                processName: "com.example.other",
                servicePort: nil
            )
        ])
    }

    func testMissingPathsDropUnpairedJobs() {
        let jobs = PresetInputParser.userLaunchAgentJobs(
            labels: "com.example.agent, com.example.second",
            paths: "/Library/LaunchAgents/com.example.agent.plist"
        )

        XCTAssertEqual(jobs, [
            UserLaunchAgentJob(
                label: "com.example.agent",
                plistPath: "/Library/LaunchAgents/com.example.agent.plist"
            )
        ])
    }
}
