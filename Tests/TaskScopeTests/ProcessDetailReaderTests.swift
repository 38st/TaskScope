import XCTest
@testable import TaskScope

final class ProcessDetailReaderTests: XCTestCase {
    func testCommandKeepsInternalSpacesAfterTheEighthField() throws {
        let line = "  42     1 alice   Sat Jul  6 11:20:17 2026 /Applications/Example  App.app/Contents/MacOS/Example  App"

        let detail = try XCTUnwrap(SystemProcessDetailReader.parseDetailLine(
            line,
            expectedStartTime: "Sat Jul 6 11:20:17 2026"
        ))

        XCTAssertEqual(detail.pid, 42)
        XCTAssertEqual(detail.parentPID, 1)
        XCTAssertEqual(detail.user, "alice")
        XCTAssertEqual(detail.startTime, "Sat Jul 6 11:20:17 2026")
        XCTAssertEqual(detail.command, "/Applications/Example  App.app/Contents/MacOS/Example  App")
    }

    func testDetailRejectsADifferentStartTimeAndShortRows() {
        XCTAssertNil(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6 11:20:17 2026 /bin/sh",
            expectedStartTime: "Sat Jul 6 11:20:18 2026"
        ))
        XCTAssertNil(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6",
            expectedStartTime: "Sat Jul 6"
        ))
    }

    func testEmptyCommandIsPreservedAsEmpty() throws {
        let detail = try XCTUnwrap(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6 11:20:17 2026",
            expectedStartTime: "Sat Jul 6 11:20:17 2026"
        ))

        XCTAssertEqual(detail.command, "")
    }
}
