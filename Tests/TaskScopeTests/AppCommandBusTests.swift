import XCTest
@testable import TaskScope

@MainActor
final class AppCommandBusTests: XCTestCase {
    func testAlreadyCancelledSubmissionDoesNotRun() async {
        let bus = AppCommandBus()
        var received = 0
        bus.install { _ in
            received += 1
            return .init(status: .completed, message: "done")
        }
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await bus.submit(.stopPreset("Example"))
        }
        let result = await caller.value
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(received, 0)
    }

    func testCancelledColdLaunchReturnsWithoutInstallingHandler() async {
        let bus = AppCommandBus()
        let submitted = BusTestLatch()
        let finished = expectation(description: "cancelled submission completes")
        let caller = Task {
            submitted.release()
            let result = await bus.submit(.stopPreset("Example"))
            XCTAssertEqual(result.status, .rejected)
            finished.fulfill()
        }
        await submitted.wait()
        caller.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await caller.value
        var received: [TaskScopeCommand] = []
        bus.install { command in
            received.append(command)
            return .init(status: .completed, message: "done")
        }
        _ = await bus.submit(.refresh)
        XCTAssertEqual(received, [.refresh])
    }

    func testCancellationBehindActiveCommandPreservesNeighbors() async {
        let bus = AppCommandBus()
        let started = BusTestLatch()
        let release = BusTestLatch()
        var received: [TaskScopeCommand] = []
        bus.install { command in
            received.append(command)
            if command == .refresh {
                started.release()
                await release.wait()
            }
            return .init(status: .completed, message: "done")
        }
        let first = Task { await bus.submit(.refresh) }
        await started.wait()
        let submitted = BusTestLatch()
        let cancelled = Task {
            submitted.release()
            return await bus.submit(.stopPreset("Cancelled"))
        }
        await submitted.wait()
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertEqual(result.status, .rejected)
        let next = Task { await bus.submit(.openPreset("Next")) }
        release.release()
        _ = await first.value
        let nextResult = await next.value
        XCTAssertTrue(nextResult.succeeded)
        XCTAssertEqual(received, [.refresh, .openPreset("Next")])
    }

    func testCancellationReachesHandlerWaitingForMutationGate() async {
        let gate = ProcessOperationGate()
        let occupied = BusTestLatch()
        let release = BusTestLatch()
        let owner = Task {
            await gate.run(kind: .mutation) {
                occupied.release()
                await release.wait()
            }
        }
        await occupied.wait()
        let bus = AppCommandBus()
        let dispatched = BusTestLatch()
        var mutations = 0
        bus.install { _ in
            dispatched.release()
            let ran = await gate.run(kind: .mutation) { mutations += 1 }
            return .init(status: ran ? .completed : .rejected, message: "gate result")
        }
        let caller = Task { await bus.submit(.stopPreset("Example")) }
        await dispatched.wait()
        caller.cancel()
        let result = await caller.value
        XCTAssertEqual(result.status, .rejected)
        release.release()
        _ = await owner.value
        XCTAssertEqual(mutations, 0)
        let next = await bus.submit(.stopPreset("Next"))
        XCTAssertTrue(next.succeeded)
        XCTAssertEqual(mutations, 1)
    }
}

@MainActor
private final class BusTestLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
