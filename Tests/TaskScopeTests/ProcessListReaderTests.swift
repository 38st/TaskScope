import XCTest
@testable import TaskScope

final class ProcessListReaderTests: XCTestCase {
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

    func testParseExtendedProcessLineCapturesStableStartTime() {
        let line = "42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /Applications/Example App.app/Contents/MacOS/Example App"[...]

        let process = ProcessListReader.parseProcessLine(line)

        XCTAssertEqual(process?.pid, 42)
        XCTAssertEqual(process?.startTime, "Sat Jul 26 11:20:17 2026")
        XCTAssertEqual(process?.elapsedTime, "01:02:03")
        XCTAssertEqual(process?.command, "/Applications/Example App.app/Contents/MacOS/Example App")
    }
}
