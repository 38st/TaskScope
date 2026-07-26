import XCTest
@testable import TaskScope

@MainActor
final class ProcessHistoryTests: XCTestCase {
    func testSamplesFullObservedPopulationAndRetainsBoundedWindow() async {
        let inventory = HistoryInventory(results: [
            .success([process(pid: 1, cpu: 10, memory: 100), process(pid: 2, cpu: 20, memory: 200)]),
            .success([process(pid: 3, cpu: 5, memory: 50)]),
            .success([])
        ])
        var timestamp = Date(timeIntervalSince1970: 100)
        let history = ProcessHistory(inventory: inventory, maxSamples: 2, now: { timestamp })

        await history.sampleNow()
        timestamp.addTimeInterval(10)
        await history.sampleNow()
        timestamp.addTimeInterval(10)
        await history.sampleNow()

        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(history.samples[0].observedProcessCPU, 5)
        XCTAssertEqual(history.samples[0].observedProcessMemoryMB, 50)
        XCTAssertEqual(history.samples[0].processCount, 1)
        XCTAssertEqual(history.samples[1].timestamp, timestamp)
        XCTAssertEqual(history.state, .sampling)
    }

    func testFailureIsVisibleAndPreservesLastGoodSamples() async {
        let inventory = HistoryInventory(results: [
            .success([process(pid: 1, cpu: 10, memory: 100)]),
            .failure(.commandFailed("ps unavailable"))
        ])
        let history = ProcessHistory(inventory: inventory)

        await history.sampleNow()
        await history.sampleNow()

        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.state, .unavailable("ps unavailable"))
    }

    private func process(pid: Int32, cpu: Double, memory: Double) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: cpu,
            memoryMB: memory,
            command: "Process\(pid)",
            elapsedTime: "00:01",
            startTime: "start\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
    }
}

private final class HistoryInventory: ProcessInventoryProviding, @unchecked Sendable {
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if results.count == 1 { return results[0] }
        return results.removeFirst()
    }
}
