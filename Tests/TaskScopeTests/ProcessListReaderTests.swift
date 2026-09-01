import XCTest
@testable import TaskScope

final class ProcessListReaderTests: XCTestCase {
    func testProductionSchemaKeepsDisplayCommandSeparateFromTrustedExecutablePath() throws {
        XCTAssertEqual(
            ProcessListReader.processListCommand,
            "/bin/ps -awwwxo pid=,ppid=,pcpu=,rss=,lstart=,etime=,comm="
        )
        XCTAssertFalse(ProcessListReader.processListCommand.contains(" -ac"))

        let liveShapedLine = "42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /Applications/Example.app/Contents/MacOS/Example"[...]
        var processes = [try XCTUnwrap(ProcessListReader.parseProcessLine(liveShapedLine))]

        XCTAssertEqual(processes[0].command, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertNil(processes[0].executablePath)

        ProcessListReader.attachExecutablePaths(
            to: &processes,
            resolvedPaths: [42: "/Applications/Example.app/Contents/MacOS/Example"],
            validatedStartTimes: [42: "Sat Jul 26 11:20:17 2026"]
        )

        XCTAssertEqual(processes[0].command, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(
            processes[0].executablePath,
            "/Applications/Example.app/Contents/MacOS/Example"
        )
        XCTAssertEqual(processes[0].displayCommand, "/Applications/Example.app/Contents/MacOS/Example")
    }

    func testExecutablePathEnrichmentFailsClosedWhenPIDStartTimeChanges() throws {
        let line = "42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 Example"[...]
        var processes = [try XCTUnwrap(ProcessListReader.parseProcessLine(line))]

        ProcessListReader.attachExecutablePaths(
            to: &processes,
            resolvedPaths: [42: "/Applications/Example.app/Contents/MacOS/Example"],
            validatedStartTimes: [42: "Sat Jul 26 11:20:18 2026"]
        )

        XCTAssertNil(processes[0].executablePath)
    }

    func testParseProcessLineHandlesCommandsWithSpaces() {
        let process = ProcessListReader.parseProcessLine(
            "123 1 12.5 2048 01:02:03 /Applications/Example App.app/Contents/MacOS/Example App"[...]
        )

        XCTAssertEqual(process?.pid, 123)
        XCTAssertEqual(process?.parentPID, 1)
        XCTAssertEqual(process?.cpu, 12.5)
        XCTAssertEqual(process?.memoryMB, 2.0)
        XCTAssertEqual(process?.elapsedTime, "01:02:03")
        XCTAssertEqual(process?.command, "/Applications/Example App.app/Contents/MacOS/Example App")
        XCTAssertNil(process?.netInKB)
        XCTAssertNil(process?.diskReadBlocks)
    }

    func testParseProcessLineRejectsMalformedRows() {
        XCTAssertNil(ProcessListReader.parseProcessLine("not enough columns"[...]))
        XCTAssertNil(ProcessListReader.parseProcessLine("abc 1 0.0 10 00:01 command"[...]))
    }

    func testProcessListOutputRejectsMixedValidAndMalformedRows() {
        let valid = "42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 Example"
        let output = "\(valid)\nmalformed partial row"

        XCTAssertEqual(
            ProcessListReader.parseProcessListOutput(output),
            .failure(.parseFailed)
        )
    }

    func testStartTimeValidationRejectsPartialMalformedOutput() {
        let output = """
        42 Sat Jul 26 11:20:17 2026
        43 Sat Jul 26
        """

        XCTAssertEqual(
            ProcessListReader.parseStartTimes(output),
            .failure(.parseFailed)
        )
    }

    func testFailedIdentityValidationCommandIsInventoryFailure() {
        let result = ShellCommandResult(
            command: ProcessListReader.identityValidationCommand,
            stdout: "",
            stderr: "ps denied",
            exitCode: 1
        )

        XCTAssertEqual(
            ProcessListReader.validatedStartTimes(from: result),
            .failure(.commandFailed("ps denied"))
        )
    }

    func testIdentityValidationOmitsProcessThatExitedBetweenSnapshots() throws {
        let result = ShellCommandResult(
            command: ProcessListReader.identityValidationCommand,
            stdout: "42 Sat Jul 26 11:20:17 2026",
            stderr: "",
            exitCode: 0
        )

        let startTimes = try ProcessListReader.validatedStartTimes(from: result).get()
        let first = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "42 1 0 100 Sat Jul 26 11:20:17 2026 00:01 First"[...]
        ))
        let exited = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "43 1 0 100 Sat Jul 26 11:20:18 2026 00:01 Exited"[...]
        ))

        XCTAssertEqual(
            ProcessListReader.validatedProcesses([first, exited], using: startTimes),
            [first]
        )
    }

    func testParseExtendedProcessLineCapturesStableStartTime() {
        let line = "42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /Applications/Example App.app/Contents/MacOS/Example App"[...]

        let process = ProcessListReader.parseProcessLine(line)

        XCTAssertEqual(process?.pid, 42)
        XCTAssertEqual(process?.startTime, "Sat Jul 26 11:20:17 2026")
        XCTAssertEqual(process?.elapsedTime, "01:02:03")
        XCTAssertEqual(process?.command, "/Applications/Example App.app/Contents/MacOS/Example App")
    }
}
