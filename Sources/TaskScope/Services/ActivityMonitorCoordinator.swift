import AppKit
import Darwin
import Foundation

enum ActivityMonitorSelectionAttempt: Equatable {
    case selected
    case notReady
    case automationDenied(String)
    case failed(String)
}

enum ActivityMonitorHandoffOutcome: Equatable {
    case success
    case missingProcess
    case appLaunchFailed(String)
    case automationDenied(String)
    case timedOut(lastError: String?)

    func message(for pid: Int32) -> String {
        switch self {
        case .success:
            "Selected PID \(pid) in Activity Monitor."
        case .missingProcess:
            "PID \(pid) is no longer running, so Activity Monitor could not select it."
        case .appLaunchFailed(let detail):
            "Could not open Activity Monitor: \(detail)"
        case .automationDenied(let detail):
            "Activity Monitor opened, but automation access was denied. Allow TaskScope to control Activity Monitor in System Settings > Privacy & Security > Automation. \(detail)"
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
}

@MainActor
protocol ActivityMonitorProcessSelecting {
    func select(pid: Int32) -> ActivityMonitorSelectionAttempt
}

@MainActor
protocol ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome
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
        guard processChecker.processExists(pid: pid) else {
            return .missingProcess
        }

        do {
            try await opener.open()
        } catch {
            return .appLaunchFailed(error.localizedDescription)
        }

        var lastError: String?
        for attempt in 0..<maximumSelectionAttempts {
            guard processChecker.processExists(pid: pid) else {
                return .missingProcess
            }

            switch selector.select(pid: pid) {
            case .selected:
                return .success
            case .automationDenied(let detail):
                return .automationDenied(detail)
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
    func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}

struct SystemActivityMonitorProcessSelector: ActivityMonitorProcessSelecting {
    func select(pid: Int32) -> ActivityMonitorSelectionAttempt {
        let source = """
        tell application "Activity Monitor"
            set matchingProcesses to every process whose unix id is \(pid)
            if (count of matchingProcesses) is 0 then return 0
            set selected processes to matchingProcesses
            return count of matchingProcesses
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not prepare the Activity Monitor automation command.")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Unknown AppleScript error."
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if number == -1743 || isAutomationDenial(message) {
                return .automationDenied(message)
            }
            return .failed(message)
        }

        return result.int32Value > 0 ? .selected : .notReady
    }

    private func isAutomationDenial(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("not authorized to send apple events")
            || normalized.contains("not permitted to send apple events")
            || normalized.contains("automation access")
    }
}
