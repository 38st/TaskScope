import XCTest
@testable import TaskScope

final class CoalescingProcessInventoryTests: XCTestCase {
    func testRecentBasicReadIsShared() async {
        let upstream = CountingCoalescingInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: false)
        _ = await inventory.load(fetchExtendedStats: false)

        let modes = await upstream.requestedModes()
        XCTAssertEqual(modes, [false])
    }

    func testExtendedReadCanServeARecentBasicRequest() async {
        let upstream = CountingCoalescingInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: true)
        _ = await inventory.load(fetchExtendedStats: false)

        let modes = await upstream.requestedModes()
        XCTAssertEqual(modes, [true])
    }

    func testIdenticalInFlightReadsJoinOneUpstreamRequest() async {
        let upstream = BlockingCoalescingInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let first = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilStarted()
        let second = Task { await inventory.load(fetchExtendedStats: false) }
        for _ in 0..<10 { await Task.yield() }

        let countWhileBlocked = await upstream.requestCount()
        XCTAssertEqual(countWhileBlocked, 1)
        await upstream.release()
        _ = await first.value
        _ = await second.value
        let finalCount = await upstream.requestCount()
        XCTAssertEqual(finalCount, 1)
    }
}

private actor CountingCoalescingInventory: ProcessInventoryProviding {
    private var modes: [Bool] = []

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        modes.append(fetchExtendedStats)
        return .success([])
    }

    func requestedModes() -> [Bool] { modes }
}

private actor BlockingCoalescingInventory: ProcessInventoryProviding {
    private var count = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { loadContinuation = $0 }
        return .success([])
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func requestCount() -> Int { count }

    func release() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
