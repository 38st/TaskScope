import Darwin
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

    func testCancellationBeforeRunDoesNotLaunchCommand() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-pre-run-\(UUID().uuidString)")
        let command = "/usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))"
        let task = Task {
            await ShellCommandRunner.run(command, timeout: 10)
        }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationDuringOutputPreservesCapturedStreams() async {
        let task = Task {
            await ShellCommandRunner.run(
                """
                i=0
                while [ $i -lt 200 ]; do
                  /usr/bin/printf 'stdout-line\n'
                  /usr/bin/printf 'stderr-line\n' >&2
                  i=$((i + 1))
                done
                /bin/sleep 5
                """,
                timeout: 10
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.stdout.contains("stdout-line"))
        XCTAssertTrue(result.stderr.contains("stderr-line"))
        XCTAssertTrue(result.stderr.hasSuffix("Command cancelled."))
    }

    func testCancellationNearChildExitCompletesExactlyOnce() async {
        for _ in 0..<20 {
            let task = Task {
                await ShellCommandRunner.run(
                    "/bin/sleep 0.01; /usr/bin/printf done",
                    timeout: 2
                )
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
            task.cancel()

            let result = await task.value
            XCTAssertTrue(
                result.exitCode == 0 || result.exitCode == -2,
                "Unexpected near-exit result: \(result)"
            )
        }
    }

    func testLargeStandardOutputAndErrorDoNotDeadlock() async {
        let byteCount = 1_048_576
        let result = await ShellCommandRunner.run(
            """
            /usr/bin/yes O | /usr/bin/head -c \(byteCount)
            /usr/bin/yes E | /usr/bin/head -c \(byteCount) >&2
            """,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, byteCount - 1)
        XCTAssertEqual(result.stderr.utf8.count, byteCount - 1)
    }

    func testTimedOutProcessIsTerminatedAndReapedBeforeReturn() async {
        let result = await ShellCommandRunner.run(
            "/usr/bin/printf $$; exec /bin/sleep 5",
            timeout: 0.1
        )
        let pid = Int32(result.stdout) ?? 0

        XCTAssertEqual(result.exitCode, -3)
        XCTAssertGreaterThan(pid, 0)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
