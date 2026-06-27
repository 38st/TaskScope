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
    }

    func testParseProcessLineRejectsMalformedRows() {
        XCTAssertNil(ProcessListReader.parseProcessLine("not enough columns"[...]))
        XCTAssertNil(ProcessListReader.parseProcessLine("abc 1 0.0 10 00:01 command"[...]))
    }
}
