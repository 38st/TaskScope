import AppKit
import Darwin
import Foundation

enum ActivityMonitorSelectionAttempt: Equatable {
    case selected
    case notReady
    case accessibilityDenied(String)
    case failed(String)
}

enum ActivityMonitorHandoffOutcome: Equatable {
    case success
    case missingProcess
    case appLaunchFailed(String)
    case accessibilityDenied(String)
    case timedOut(lastError: String?)

    func message(for pid: Int32) -> String {
        switch self {
        case .success:
            "Selected PID \(pid) in Activity Monitor."
        case .missingProcess:
            "PID \(pid) is no longer running or its identity could not be verified, so Activity Monitor could not select it."
        case .appLaunchFailed(let detail):
            "Could not open Activity Monitor: \(detail)"
        case .accessibilityDenied(let detail):
            "Activity Monitor opened, but Accessibility access is not granted. Allow TaskScope in System Settings > Privacy & Security > Accessibility, then try again. \(detail)"
        case .timedOut(let lastError):
            if let lastError, !lastError.isEmpty {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out: \(lastError)"
            } else {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out."
            }
        }
    }
}

@MainActor
protocol ActivityMonitorOpening {
    func open() async throws
}

@MainActor
protocol ActivityMonitorProcessChecking {
    func processExists(pid: Int32) -> Bool
    func processMatches(identity: ProcessIdentity) -> Bool
}

extension ActivityMonitorProcessChecking {
    // Checkers without identity evidence must not approve a row-based handoff.
    func processMatches(identity: ProcessIdentity) -> Bool { false }
}

@MainActor
protocol ActivityMonitorProcessSelecting {
    /// Async so the Accessibility traversal can run off the main actor.
    func select(pid: Int32) async -> ActivityMonitorSelectionAttempt
    /// Puts back any Activity Monitor state a handoff changed, without waiting
    /// for the scheduled restoration delay.
    func restorePreparedState()
}

extension ActivityMonitorProcessSelecting {
    func restorePreparedState() {}
}

@MainActor
protocol ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome
    func restoreActivityMonitorState()
}

extension ActivityMonitorCoordinating {
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome { .missingProcess }
    func restoreActivityMonitorState() {}
}

@MainActor
final class ActivityMonitorCoordinator: ActivityMonitorCoordinating {
    private let opener: any ActivityMonitorOpening
    private let processChecker: any ActivityMonitorProcessChecking
    private let selector: any ActivityMonitorProcessSelecting
    private let maximumSelectionAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let sleep: @MainActor (UInt64) async -> Void

    convenience init() {
        self.init(
            opener: SystemActivityMonitorOpener(),
            processChecker: SystemActivityMonitorProcessChecker(),
            selector: SystemActivityMonitorProcessSelector()
        )
    }

    init(
        opener: any ActivityMonitorOpening,
        processChecker: any ActivityMonitorProcessChecking,
        selector: any ActivityMonitorProcessSelecting,
        maximumSelectionAttempts: Int = 8,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        sleep: @escaping @MainActor (UInt64) async -> Void = { duration in
            try? await Task.sleep(nanoseconds: duration)
        }
    ) {
        self.opener = opener
        self.processChecker = processChecker
        self.selector = selector
        self.maximumSelectionAttempts = max(1, maximumSelectionAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.sleep = sleep
    }

    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome {
        await openAndSelect(pid: pid, identity: nil)
    }

    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        await openAndSelect(pid: identity.pid, identity: identity)
    }

    private func openAndSelect(pid: Int32, identity: ProcessIdentity?) async -> ActivityMonitorHandoffOutcome {
        func processMatches() -> Bool {
            if let identity { return processChecker.processMatches(identity: identity) }
            return processChecker.processExists(pid: pid)
        }

        guard processMatches() else {
            return .missingProcess
        }

        do {
            try await opener.open()
        } catch {
            return .appLaunchFailed(error.localizedDescription)
        }

        var lastError: String?
        for attempt in 0..<maximumSelectionAttempts {
            guard processMatches() else {
                return .missingProcess
            }

            switch await selector.select(pid: pid) {
            case .selected:
                // Selection suspends for Accessibility work; do not report success
                // if the selected process changed while that work was in flight.
                if identity != nil, !processMatches() { return .missingProcess }
                return .success
            case .accessibilityDenied(let detail):
                return .accessibilityDenied(detail)
            case .failed(let detail):
                lastError = detail
            case .notReady:
                break
            }

            if attempt < maximumSelectionAttempts - 1 {
                await sleep(retryDelayNanoseconds)
            }
        }

        return .timedOut(lastError: lastError)
    }

    /// Called on app termination so a handoff whose restoration delay has not
    /// elapsed still leaves Activity Monitor as the user had it.
    func restoreActivityMonitorState() {
        selector.restorePreparedState()
    }
}

struct SystemActivityMonitorOpener: ActivityMonitorOpening {
    private static let applicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"
    )

    func open() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: Self.applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: ActivityMonitorOpenError.noApplicationReturned)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum ActivityMonitorOpenError: LocalizedError {
    case noApplicationReturned

    var errorDescription: String? {
        "macOS did not return a running Activity Monitor application."
    }
}

struct SystemActivityMonitorProcessChecker: ActivityMonitorProcessChecking {
    private let readStartTime: (Int32) -> (seconds: UInt64, microseconds: UInt64)?
    private let executablePathForPID: (Int32) -> String?

    init(
        readStartTime: ((Int32) -> (seconds: UInt64, microseconds: UInt64)?)? = nil,
        executablePathForPID: ((Int32) -> String?)? = nil
    ) {
        self.readStartTime = readStartTime ?? Self.startTime
        self.executablePathForPID = executablePathForPID ?? ProcessListReader.executablePath
    }

    func processMatches(identity: ProcessIdentity) -> Bool {
        guard identity.pid > 0,
              !identity.startTime.isEmpty,
              let expectedPath = identity.executablePath, !expectedPath.isEmpty,
              let start = readStartTime(identity.pid),
              let path = executablePathForPID(identity.pid), path == expectedPath,
              let verifiedStart = readStartTime(identity.pid), start == verifiedStart else { return false }

        // The inventory's `ps lstart` is normalized to C-locale UTC seconds.
        // Check the kernel start time on both sides of the kernel path read.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(start.seconds))) == identity.startTime
    }

    private static func startTime(for pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
        // Unlike PROC_PIDTBSDINFO, KERN_PROC_PID exposes the same start-time
        // evidence as ps for visible processes owned by other users too.
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid, info.kp_proc.p_stat != UInt8(SZOMB) else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0 else { return nil }
        return (UInt64(start.tv_sec), UInt64(start.tv_usec))
    }

    func processExists(pid: Int32) -> Bool {
        pid > 0 && readStartTime(pid) != nil
    }
}
