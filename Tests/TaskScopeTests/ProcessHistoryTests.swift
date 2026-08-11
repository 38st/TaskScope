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

    func testStopDiscardsResultFromInFlightSamplingGeneration() async {
        let inventory = BlockingHistoryInventory(
            firstResult: .success([process(pid: 1, cpu: 10, memory: 100)]),
            laterResult: .success([])
        )
        let history = ProcessHistory(inventory: inventory)

        history.start(cadence: 2)
        await inventory.waitForFirstLoad()
        history.stop()
        await inventory.releaseFirstLoad()
        await inventory.waitForFirstReturn()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples, [])
    }

    func testRestartDiscardsResultFromPreviousSamplingGeneration() async {
        let stale = process(pid: 1, cpu: 10, memory: 100)
        let current = process(pid: 2, cpu: 20, memory: 200)
        let inventory = BlockingHistoryInventory(
            firstResult: .success([stale]),
            laterResult: .success([current])
        )
        let history = ProcessHistory(inventory: inventory)

        history.start(cadence: 2)
        await inventory.waitForFirstLoad()
        history.start(cadence: 2)
        for _ in 0..<100 where history.samples.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [20])

        await inventory.releaseFirstLoad()
        await inventory.waitForFirstReturn()
        for _ in 0..<10 { await Task.yield() }

        history.stop()
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [20])
        XCTAssertEqual(history.state, .paused)
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

private actor BlockingHistoryInventory: ProcessInventoryProviding {
    private let firstResult: Result<[AppProcess], ProcessInventoryError>
    private let laterResult: Result<[AppProcess], ProcessInventoryError>
    private var loadCount = 0
    private var firstLoadStarted = false
    private var firstLoadReturned = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    init(
        firstResult: Result<[AppProcess], ProcessInventoryError>,
        laterResult: Result<[AppProcess], ProcessInventoryError>
    ) {
        self.firstResult = firstResult
        self.laterResult = laterResult
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        loadCount += 1
        guard loadCount == 1 else { return laterResult }

        firstLoadStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstLoadContinuation = continuation
        }
        firstLoadReturned = true
        returnWaiters.forEach { $0.resume() }
        returnWaiters.removeAll()
        return firstResult
    }

    func waitForFirstLoad() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func waitForFirstReturn() async {
        guard !firstLoadReturned else { return }
        await withCheckedContinuation { continuation in
            returnWaiters.append(continuation)
        }
    }
}
