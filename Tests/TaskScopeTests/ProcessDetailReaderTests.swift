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

    func testStartTimeIsReadInUTCAndShownInTheViewersTimeZone() {
        let detail = ProcessDetail(pid: 1, parentPID: 0, user: "me", startTime: "Wed Oct 7 17:04:47 2026", command: "")
        let shown = detail.displayStartTime(
            timeZone: TimeZone(identifier: "America/New_York")!,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(shown.contains("Oct 7, 2026"), shown)
        XCTAssertTrue(shown.contains("1:04:47"), shown)

        let unparsed = ProcessDetail(pid: 1, parentPID: 0, user: "me", startTime: "unexpected", command: "")
        XCTAssertEqual(unparsed.displayStartTime(), "unexpected UTC")
    }
}
