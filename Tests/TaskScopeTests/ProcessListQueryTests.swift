import XCTest
@testable import TaskScope

final class ProcessListQueryTests: XCTestCase {
    func testSearchMatchesNameCommandAndPIDCaseInsensitively() {
        let process = makeProcess(name: "ExampleAgent", command: "/Applications/Example.app/ExampleAgent", pid: 42)

        XCTAssertTrue(query(search: "agent").matches(process))
        XCTAssertTrue(query(search: "applications/example").matches(process))
        XCTAssertTrue(query(search: "42").matches(process))
        XCTAssertFalse(query(search: "missing").matches(process))
    }

    func testWatchedAndHighlightedFiltersUseTheirConfiguredBoundaries() {
        let process = makeProcess(name: "Example", cpu: 30, memory: 500)

        XCTAssertTrue(query(mode: .watched, watchedNames: ["Example"]).matches(process))
        XCTAssertFalse(query(mode: .watched, watchedNames: ["Other"]).matches(process))
        XCTAssertTrue(query(mode: .highlighted, cpu: 30, memory: 1_000).matches(process))
        XCTAssertTrue(query(mode: .highlighted, cpu: 100, memory: 500).matches(process))
        XCTAssertFalse(query(mode: .highlighted, cpu: 31, memory: 501).matches(process))
    }

    private func query(
        search: String = "",
        mode: ProcessFilterMode = .all,
        watchedNames: Set<String> = [],
        cpu: Double = 30,
        memory: Double = 500
    ) -> ProcessListQuery {
        ProcessListQuery(
            searchText: search,
            filterMode: mode,
            watchedNames: watchedNames,
            cpuHighlightThreshold: cpu,
            memoryHighlightThresholdMB: memory
        )
    }

    private func makeProcess(
        name: String,
        command: String? = nil,
        pid: Int32 = 1,
        cpu: Double = 0,
        memory: Double = 0
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 0,
            cpu: cpu,
            memoryMB: memory,
            command: command ?? "/tmp/\(name)",
            elapsedTime: "00:01",
            startTime: "start",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}
