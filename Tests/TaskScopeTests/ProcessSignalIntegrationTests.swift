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

    /// `kill(pid, 0)` still succeeds for a zombie, which has already exited and
    /// only awaits `waitpid`. Liveness must consult the kernel state.
    func testZombieIsNotReportedAlive() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil), 0)
        defer {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        var isZombie = false
        for _ in 0..<400 where !isZombie {
            isZombie = ProcessSignalGuard.isZombie(pid)
            if !isZombie { usleep(5_000) }
        }
        XCTAssertTrue(isZombie, "precondition: the child became a zombie")
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "precondition: kill(pid, 0) succeeds for a zombie")

        XCTAssertFalse(DarwinProcessSignaler().isAlive(pid))
    }

    /// Signal 0 is harmless, so the guard can be exercised against the real
    /// kernel: `kill(0, 0)` would succeed, and pid 1 exists, if they were not
    /// refused before the call.
    func testSignalGuardRefusesProcessGroupAndLaunchdPIDs() {
        let signaler = DarwinProcessSignaler()

        XCTAssertEqual(signaler.deliver(0, to: 0), .rejected(errno: EINVAL))
        XCTAssertFalse(signaler.send(0, to: 1))
        XCTAssertFalse(signaler.send(0, to: -1))
        XCTAssertFalse(signaler.isAlive(0))
        XCTAssertFalse(signaler.isAlive(1))
    }

    func testDeliveryDistinguishesAVanishedProcessFromARejectedSignal() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil), 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)

        XCTAssertEqual(DarwinProcessSignaler().deliver(0, to: pid), .noSuchProcess)
        XCTAssertEqual(DarwinProcessSignaler().deliver(0, to: 1), .rejected(errno: EINVAL))
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
