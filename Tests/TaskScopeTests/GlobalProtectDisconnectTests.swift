import XCTest
@testable import TaskScope

final class GlobalProtectDisconnectTests: XCTestCase {
    func testConnectionFailureRequiresTheCompleteIdleView() async {
        let idle = GlobalProtectConnectionObservation(
            status: "Error", showsConnectionFailed: true, canConnect: true, hasDisconnect: false
        )
        XCTAssertEqual(idle.state, .disconnected)
        let runtime = FakeDisconnectRuntime(states: [idle.state])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 5)
        XCTAssertEqual(counts.presses, 0)
    }

    func testErrorOrIncompleteAndContradictoryFailureControlsNeverAuthorizeShutdown() {
        for observation in [
            GlobalProtectConnectionObservation(status: "Error"),
            GlobalProtectConnectionObservation(status: "Error", showsConnectionFailed: true),
            GlobalProtectConnectionObservation(status: "Error", canConnect: true),
            GlobalProtectConnectionObservation(status: "Error", showsConnectionFailed: true, canConnect: true, hasDisconnect: true),
            GlobalProtectConnectionObservation(status: nil, showsConnectionFailed: true, canConnect: true),
            GlobalProtectConnectionObservation(status: "Unknown", showsConnectionFailed: true, canConnect: true)
        ] {
            XCTAssertEqual(observation.state, .unavailable)
        }
        for (status, expected) in [("Connected", GlobalProtectConnectionState.connected), ("Connecting...", .busy), ("Disconnecting...", .busy)] {
            XCTAssertEqual(GlobalProtectConnectionObservation(status: status, showsConnectionFailed: true, canConnect: true).state, expected)
        }
    }

    func testConnectedVPNIsDisconnectedOnceAndWaitsForStableDisconnectedState() async {
        let runtime = FakeDisconnectRuntime(states: [
            .connected, .connected, .busy, .disconnected, .busy,
            .disconnected, .disconnected, .disconnected, .disconnected, .disconnected
        ])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.presses, 1)
        XCTAssertEqual(counts.reads, 10)
    }

    /// A just-launched interface needs time to create its menu bar item. The
    /// startup budget covers that, and once state is readable the normal
    /// three-strike limit applies again.
    func testJustLaunchedInterfaceGetsAStartupBudgetBeforeItsFirstReadableState() async {
        let lateStart = FakeDisconnectRuntime(
            states: Array(repeating: .unavailable, count: 8) + [.disconnected]
        )
        let launched = await GlobalProtectDisconnectController.disconnect(
            using: lateStart,
            startupUnavailableObservations: 20
        )
        XCTAssertEqual(launched, .disconnected)

        let alreadyRunning = FakeDisconnectRuntime(
            states: Array(repeating: .unavailable, count: 8) + [.disconnected]
        )
        let running = await GlobalProtectDisconnectController.disconnect(using: alreadyRunning)
        XCTAssertNotEqual(running, .disconnected)

        let lostAfterStart = FakeDisconnectRuntime(
            states: [.disconnected, .unavailable, .unavailable, .unavailable, .disconnected]
        )
        let lost = await GlobalProtectDisconnectController.disconnect(
            using: lostAfterStart,
            startupUnavailableObservations: 20
        )
        XCTAssertNotEqual(lost, .disconnected, "the startup budget must not extend past the first readable state")
    }

    func testIdleVPNDoesNotPressDisconnect() async {
        let runtime = FakeDisconnectRuntime(states: [.disconnected])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.presses, 0)
        XCTAssertEqual(counts.reads, 5)
    }

    func testLostPopoverCanRecoverButResetsTheIdleObservationStreak() async {
        let runtime = FakeDisconnectRuntime(states: [
            .disconnected, .disconnected, .unavailable, .unavailable,
            .disconnected, .disconnected, .disconnected, .disconnected, .disconnected
        ])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 9)
        XCTAssertEqual(counts.presses, 0)
    }

    func testPersistentlyUnreadableStateFailsAfterBoundedRetries() async {
        let runtime = FakeDisconnectRuntime(states: [.unavailable])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        guard case .failed(let detail) = result else { return XCTFail("Unreadable state must fail") }
        XCTAssertTrue(detail.contains("could not verify"))
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(counts.presses, 0)
    }

    func testFailedPressUnknownStateAndTimeoutNeverReportDisconnected() async {
        for runtime in [
            FakeDisconnectRuntime(states: [.connected], pressSucceeds: false),
            FakeDisconnectRuntime(states: [.unavailable]),
            FakeDisconnectRuntime(states: [.connected, .busy]),
            FakeDisconnectRuntime(states: [.busy])
        ] {
            let result = await GlobalProtectDisconnectController.disconnect(using: runtime, observationLimit: 6)
            guard case .failed = result else { return XCTFail("Unverified disconnect reported success") }
        }
    }
}

private actor FakeDisconnectRuntime: GlobalProtectDisconnectRuntime {
    private var states: [GlobalProtectConnectionState]
    private let pressSucceeds: Bool
    private var reads = 0
    private var presses = 0

    init(states: [GlobalProtectConnectionState], pressSucceeds: Bool = true) {
        self.states = states
        self.pressSucceeds = pressSucceeds
    }

    func connectionState() async -> GlobalProtectConnectionState {
        reads += 1
        if states.count > 1 { return states.removeFirst() }
        return states[0]
    }

    func pressDisconnect() async -> Bool {
        presses += 1
        return pressSucceeds
    }

    func waitForNextObservation() async {}
    func counts() -> (reads: Int, presses: Int) { (reads, presses) }
}
