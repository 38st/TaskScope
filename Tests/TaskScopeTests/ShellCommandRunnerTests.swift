import XCTest
@testable import TaskScope

final class ShellCommandRunnerTests: XCTestCase {
    func testExtendedRegexLiteralEscapesProcessNameMetacharacters() {
        XCTAssertEqual(
            ShellCommandRunner.extendedRegexLiteral("Codex (Renderer)+[1].app"),
            #"Codex \(Renderer\)\+\[1\]\.app"#
        )
    }

    func testRunCapturesOutputAndExitStatus() async {
        let result = await ShellCommandRunner.run(
            "/usr/bin/printf 'standard output'; /usr/bin/printf 'standard error' >&2; exit 7"
        )

        XCTAssertEqual(result.stdout, "standard output")
        XCTAssertEqual(result.stderr, "standard error")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testRunTimesOutAndReturnsPromptly() async {
        let started = Date()

        let result = await ShellCommandRunner.run("/bin/sleep 5", timeout: 0.1)

        XCTAssertEqual(result.exitCode, -3)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRunRespondsToTaskCancellation() async {
        let started = Date()
        let task = Task {
            await ShellCommandRunner.run("/bin/sleep 5", timeout: 10)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertEqual(result.stderr, "Command cancelled.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
