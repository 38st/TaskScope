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

    /// A basic read that started first but finishes last must not replace the
    /// newer extended result that completed while it was blocked.
    func testAnOlderReadThatFinishesLateDoesNotOverwriteANewerCachedResult() async {
        let upstream = ModeBlockingCoalescingInventory(
            basic: [process(pid: 1, name: "OldBasic")],
            extended: [process(pid: 2, name: "NewExtended")]
        )
        let clock = TestClock()
        let inventory = CoalescingProcessInventory(
            upstream: upstream,
            maximumAge: 60,
            now: { clock.now() }
        )

        let basic = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilBasicStarted()
        clock.advance(1)
        let extended = await inventory.load(fetchExtendedStats: true)
        XCTAssertEqual(try extended.get().map(\.name), ["NewExtended"])

        await upstream.releaseBasic()
        _ = await basic.value

        let served = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try served.get().map(\.name), ["NewExtended"], "the older basic read must not win")
    }

    func testFailuresAreNeverCached() async {
        let upstream = ScriptedCoalescingInventory(results: [
            .failure(.commandFailed("ps unavailable")),
            .success([process(pid: 1, name: "Recovered")])
        ])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        let first = await inventory.load(fetchExtendedStats: false)
        let second = await inventory.load(fetchExtendedStats: false)
        let third = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(first, .failure(.commandFailed("ps unavailable")))
        XCTAssertEqual(try second.get().map(\.name), ["Recovered"])
        XCTAssertEqual(try third.get().map(\.name), ["Recovered"])
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 2, "the failure must not be served from cache; the success must")
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

private func process(pid: Int32, name: String) -> AppProcess {
    AppProcess(
        pid: pid,
        parentPID: 1,
        cpu: 0,
        memoryMB: 0,
        command: "/tmp/\(name)",
        elapsedTime: "00:01",
        startTime: "start-\(pid)",
        netInKB: nil,
        netOutKB: nil,
        diskReadBytes: nil,
        diskWriteBytes: nil
    )
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private actor ScriptedCoalescingInventory: ProcessInventoryProviding {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private var calls = 0

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        guard !results.isEmpty else { return .failure(.commandFailed("exhausted")) }
        return results.count == 1 ? results[0] : results.removeFirst()
    }

    func callCount() -> Int { calls }
}

/// Blocks basic reads until released while extended reads complete at once.
private actor ModeBlockingCoalescingInventory: ProcessInventoryProviding {
    private let basic: [AppProcess]
    private let extended: [AppProcess]
    private var basicStarted = false
    private var basicWaiters: [CheckedContinuation<Void, Never>] = []
    private var basicContinuation: CheckedContinuation<Void, Never>?

    init(basic: [AppProcess], extended: [AppProcess]) {
        self.basic = basic
        self.extended = extended
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if fetchExtendedStats {
            return .success(extended)
        }
        basicStarted = true
        basicWaiters.forEach { $0.resume() }
        basicWaiters.removeAll()
        await withCheckedContinuation { basicContinuation = $0 }
        return .success(basic)
    }

    func waitUntilBasicStarted() async {
        guard !basicStarted else { return }
        await withCheckedContinuation { basicWaiters.append($0) }
    }

    func releaseBasic() {
        basicContinuation?.resume()
        basicContinuation = nil
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
