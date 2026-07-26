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

    func testSystemLaunchDaemonJobsPreservePositionalOptionalPorts() {
        let result = PresetInputParser.parseSystemLaunchDaemonJobs(
            labels: "com.example.daemon, com.example.other",
            paths: "/Library/LaunchDaemons/com.example.daemon.plist, /Library/LaunchDaemons/com.example.other.plist",
            processNames: "ExampleDaemon,",
            ports: ",4321"
        )

        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.value, [
            SystemLaunchDaemonJob(
                label: "com.example.daemon",
                plistPath: "/Library/LaunchDaemons/com.example.daemon.plist",
                processName: "ExampleDaemon",
                servicePort: nil
            ),
            SystemLaunchDaemonJob(
                label: "com.example.other",
                plistPath: "/Library/LaunchDaemons/com.example.other.plist",
                processName: "com.example.other",
                servicePort: 4321
            )
        ])
    }

    func testMissingPathsAreRejectedInsteadOfSilentlyDroppingJobs() {
        let result = PresetInputParser.parseUserLaunchAgentJobs(
            labels: "com.example.agent, com.example.second",
            paths: "/Library/LaunchAgents/com.example.agent.plist"
        )

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testInvalidPortReportsItsPositionAndDoesNotShiftLaterItems() {
        let result = PresetInputParser.parseSystemLaunchDaemonJobs(
            labels: "one, two, three",
            paths: "/one.plist, /two.plist, /three.plist",
            processNames: "one, two, three",
            ports: "1234, invalid, 4321"
        )

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(result.errors, ["Daemon port item 2 is invalid: invalid."])
    }
}
