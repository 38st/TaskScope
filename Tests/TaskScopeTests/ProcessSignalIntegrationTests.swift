import Darwin
import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class ProcessSignalIntegrationTests: XCTestCase {
    func testGracefulStopLetsControlledChildExitWithoutSIGKILL() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            "trap 'sleep 1; exit 0' TERM; while :; do sleep 0.05; done"
        ]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
        }

        // Give the controlled child time to install its TERM handler.
        try await Task.sleep(nanoseconds: 150_000_000)

        let target = AppProcess(
            pid: pid,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            cpu: 0,
            memoryMB: 0,
            command: "/tmp/TaskScope Controlled Child",
            elapsedTime: "00:01",
            startTime: "controlled-child-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBlocks: nil,
            diskWriteBlocks: nil
        )
        let signaler = RecordingDarwinSignaler()
        let manager = ProcessManager(
            processInventory: FixedProcessInventory(processes: [target]),
            processSignaler: signaler,
            settleAfterProcessChange: {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            }
        )
        manager.enableNotifications = false

        let startedAt = ContinuousClock.now
        let result = await manager.terminate(target)
        let elapsed = startedAt.duration(to: .now)

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signaler.sentSignals, [SIGTERM])
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(1))
        XCTAssertFalse(child.isRunning)
    }
}

private struct FixedProcessInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class RecordingDarwinSignaler: ProcessSignaling {
    private let lock = NSLock()
    private var signals: [Int32] = []

    var sentSignals: [Int32] {
        lock.withLock { signals }
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        lock.withLock {
            signals.append(signal)
        }
        return Darwin.kill(pid, signal) == 0
    }

    func isAlive(_ pid: Int32) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}
