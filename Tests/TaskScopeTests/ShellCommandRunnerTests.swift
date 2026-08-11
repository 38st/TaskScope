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

    func testTimeoutTerminatesDescendantsThatIgnoreTermAndHoldPipesOpen() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-timeout-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let started = Date()
        let result = await ShellCommandRunner.run(
            descendantHoldingPipesCommand(marker: marker),
            timeout: 0.25
        )
        let pids = try processIdentifiers(from: marker)
        XCTAssertEqual(result.exitCode, -3)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await assertProcessDisappears(pids.descendant)
    }

    func testCancellationTerminatesDescendantsThatIgnoreTermAndHoldPipesOpen() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-cancel-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let started = Date()
        let command = descendantHoldingPipesCommand(marker: marker)
        let task = Task {
            await ShellCommandRunner.run(command, timeout: 10)
        }

        let pids = try await waitForProcessIdentifiers(from: marker)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.stderr.hasSuffix("Command cancelled."))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await assertProcessDisappears(pids.descendant)
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
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-output-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            await ShellCommandRunner.run(
                """
                /usr/bin/printf 'stdout-line\n'
                /usr/bin/printf 'stderr-line\n' >&2
                /usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))
                /bin/sleep 5
                """,
                timeout: 10
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "The controlled child never reached its cancellation handshake."
        )

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

    private func descendantHoldingPipesCommand(marker: URL) -> String {
        """
        /bin/sh -c 'trap "" TERM; /bin/sleep 5' &
        descendant=$!
        /usr/bin/printf '%s:%s' $$ "$descendant" > \(ShellCommandRunner.shellQuoted(marker.path))
        wait "$descendant"
        """
    }

    private func processIdentifiers(from marker: URL) throws -> (group: Int32, descendant: Int32) {
        let contents = try String(contentsOf: marker, encoding: .utf8)
        let components = contents.split(separator: ":")
        guard components.count == 2,
              let group = Int32(components[0]),
              let descendant = Int32(components[1]) else {
            XCTFail("Invalid process-group handshake: \(contents)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return (group, descendant)
    }

    private func waitForProcessIdentifiers(
        from marker: URL
    ) async throws -> (group: Int32, descendant: Int32) {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: marker, encoding: .utf8) {
                let components = contents.split(separator: ":")
                if components.count == 2,
                   let group = Int32(components[0]),
                   let descendant = Int32(components[1]) {
                    return (group, descendant)
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return try processIdentifiers(from: marker)
    }

    private func assertProcessDisappears(
        _ pid: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Descendant PID \(pid) survived command termination.", file: file, line: line)
    }
}
