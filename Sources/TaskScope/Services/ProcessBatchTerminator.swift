import Darwin
import Foundation

protocol ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool
    /// Like `send`, but distinguishes a target that no longer exists from a
    /// signal the kernel refused.
    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery
    func isAlive(_ pid: Int32) -> Bool
}

extension ProcessSignaling {
    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        send(signal, to: pid) ? .delivered : .rejected(errno: EPERM)
    }
}

struct DarwinProcessSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        deliver(signal, to: pid) == .delivered
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        guard ProcessSignalGuard.isSignalablePID(pid) else {
            return .rejected(errno: EINVAL)
        }
        errno = 0
        if Darwin.kill(pid, signal) == 0 {
            return .delivered
        }
        let code = errno
        return code == ESRCH ? .noSuchProcess : .rejected(errno: code)
    }

    func isAlive(_ pid: Int32) -> Bool {
        guard ProcessSignalGuard.isSignalablePID(pid) else { return false }
        errno = 0
        let result = Darwin.kill(pid, 0)
        guard result == 0 || errno == EPERM else { return false }
        return !ProcessSignalGuard.isZombie(pid)
    }
}

struct ProcessBatchTerminationOutcome {
    var report: ProcessBatchActionReport
    var message: String
    var inventoryError: String?
    var shouldClearSelection: Bool
    var shouldRefresh: Bool
}

/// Revalidates a captured selection and performs one batch signal operation.
/// Presentation state and post-mutation inventory publishing remain owned by
/// `ProcessManager`.
@MainActor
struct ProcessBatchTerminator {
    private let inventory: any ProcessInventoryProviding
    private let signaler: any ProcessSignaling
    private let settleAfterProcessChange: () async -> Void
    private let currentPID: Int32

    init(
        inventory: any ProcessInventoryProviding,
        signaler: any ProcessSignaling,
        settleAfterProcessChange: @escaping () async -> Void,
        currentPID: Int32
    ) {
        self.inventory = inventory
        self.signaler = signaler
        self.settleAfterProcessChange = settleAfterProcessChange
        self.currentPID = currentPID
    }

    func terminate(
        _ requestedIdentities: [ProcessIdentity],
        forceKill: Bool
    ) async -> ProcessBatchTerminationOutcome {
        let title = forceKill ? "Force Stop Results" : "Stop Results"
        let inventoryResult = await inventory.load(fetchExtendedStats: false)
        guard case .success(let currentProcesses) = inventoryResult else {
            let error: String?
            if case .failure(let inventoryError) = inventoryResult {
                error = inventoryError.localizedDescription
            } else {
                error = nil
            }
            return ProcessBatchTerminationOutcome(
                report: ProcessBatchActionReport(
                    title: title,
                    targets: requestedIdentities.map {
                        ProcessTargetActionResult(
                            identity: $0,
                            name: displayName(for: $0),
                            state: .unverified
                        )
                    }
                ),
                message: "Could not verify selected processes.",
                inventoryError: error,
                shouldClearSelection: false,
                shouldRefresh: false
            )
        }

        let currentByIdentity = Dictionary(
            currentProcesses.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let verified = requestedIdentities.compactMap { currentByIdentity[$0] }
        var targetResults = requestedIdentities.compactMap { identity -> ProcessTargetActionResult? in
            guard currentByIdentity[identity] == nil else { return nil }
            return ProcessTargetActionResult(
                identity: identity,
                name: displayName(for: identity),
                state: .stale
            )
        }
        let staleCount = targetResults.count
        let selfTargets = verified.filter { $0.pid == currentPID }
        targetResults.append(contentsOf: selfTargets.map {
            ProcessTargetActionResult(
                identity: $0.identity,
                name: $0.name,
                state: .selfProcess
            )
        })
        // A pid that may never be signalled (0, negative, or launchd) cannot
        // come from the parser, but the guard is enforced here regardless.
        let unsignalable = verified.filter {
            $0.pid != currentPID && !ProcessSignalGuard.isSignalablePID($0.pid)
        }
        targetResults.append(contentsOf: unsignalable.map {
            ProcessTargetActionResult(
                identity: $0.identity,
                name: $0.name,
                state: .signalRejected
            )
        })
        let signalTargets = verified.filter {
            $0.pid != currentPID && ProcessSignalGuard.isSignalablePID($0.pid)
        }
        guard !signalTargets.isEmpty else {
            sort(&targetResults, by: requestedIdentities)
            let message: String
            if selfTargets.isEmpty {
                message = "Selection changed; \(staleCount) no longer matched. Nothing was stopped."
            } else if staleCount == 0 {
                message = "TaskScope cannot stop itself; use Quit."
            } else {
                message = "Nothing was stopped; \(selfTargets.count) TaskScope target rejected, \(staleCount) no longer matched."
            }
            return ProcessBatchTerminationOutcome(
                report: ProcessBatchActionReport(title: title, targets: targetResults),
                message: message,
                inventoryError: nil,
                shouldClearSelection: true,
                shouldRefresh: true
            )
        }

        let signal: Int32 = forceKill ? SIGKILL : SIGTERM
        var acceptedIdentities: Set<ProcessIdentity> = []
        for process in signalTargets {
            switch signaler.deliver(signal, to: process.pid) {
            case .delivered:
                acceptedIdentities.insert(process.identity)
            case .noSuchProcess:
                // It exited between the identity check and the signal; the
                // requested outcome holds, so this is not a rejected signal.
                targetResults.append(ProcessTargetActionResult(
                    identity: process.identity,
                    name: process.name,
                    state: .stopped
                ))
            case .rejected:
                targetResults.append(ProcessTargetActionResult(
                    identity: process.identity,
                    name: process.name,
                    state: .signalRejected
                ))
            }
        }
        await settleAfterProcessChange()

        for process in signalTargets where acceptedIdentities.contains(process.identity) {
            targetResults.append(ProcessTargetActionResult(
                identity: process.identity,
                name: process.name,
                state: signaler.isAlive(process.pid) ? .requestedStillRunning : .stopped
            ))
        }
        sort(&targetResults, by: requestedIdentities)

        let accepted = acceptedIdentities.count
        let stopped = targetResults.filter { $0.state == .stopped }.count
        let message: String
        if forceKill {
            message = "Force stopped \(stopped) of \(requestedIdentities.count) selected."
        } else if accepted == 0, stopped == 0 {
            message = "Could not send stop to the selected processes."
        } else if stopped == signalTargets.count, staleCount == 0, selfTargets.isEmpty {
            message = "Stopped \(stopped) of \(requestedIdentities.count) selected."
        } else {
            let stillRunning = signalTargets.count - stopped
            if selfTargets.isEmpty {
                message = "Stop requested; \(stillRunning) still running, \(staleCount) no longer matched."
            } else {
                message = "Stop requested; \(stillRunning) still running, \(selfTargets.count) TaskScope target rejected, \(staleCount) no longer matched."
            }
        }

        return ProcessBatchTerminationOutcome(
            report: ProcessBatchActionReport(title: title, targets: targetResults),
            message: message,
            inventoryError: nil,
            shouldClearSelection: true,
            shouldRefresh: true
        )
    }

    private func displayName(for identity: ProcessIdentity) -> String {
        identity.command.isEmpty
            ? "PID \(identity.pid)"
            : URL(fileURLWithPath: identity.command).lastPathComponent
    }

    private func sort(
        _ results: inout [ProcessTargetActionResult],
        by requestedIdentities: [ProcessIdentity]
    ) {
        results.sort { lhs, rhs in
            let lhsIndex = requestedIdentities.firstIndex(of: lhs.identity) ?? Int.max
            let rhsIndex = requestedIdentities.firstIndex(of: rhs.identity) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }
}
