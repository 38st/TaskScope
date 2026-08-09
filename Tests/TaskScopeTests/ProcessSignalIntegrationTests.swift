import Darwin
import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class ProcessSignalIntegrationTests: XCTestCase {
    func testGracefulStopLetsControlledChildExitWithoutSIGKILL() async throws {
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-signal-ready-\(UUID().uuidString)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            "trap 'sleep 1; exit 0' TERM; /usr/bin/touch \(ShellCommandRunner.shellQuoted(readyMarker.path)); while :; do sleep 0.05; done"
        ]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: readyMarker)
        }

        guard try await waitForMarker(readyMarker) else {
            XCTFail("Controlled child did not report that its TERM handler was ready.")
            return
        }

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

    private func waitForMarker(_ marker: URL) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return FileManager.default.fileExists(atPath: marker.path)
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
