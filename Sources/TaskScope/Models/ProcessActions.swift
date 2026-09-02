import Darwin

enum ProcessActionResult: Equatable, Sendable {
    case stopped
    case requestedStillRunning
    case stale
    case rejected

    var succeeded: Bool {
        self == .stopped
    }

    /// A stop signal was accepted but the process had not exited when it was
    /// last checked. The outcome is decided by a later observation, not by
    /// re-signalling immediately.
    var isAwaitingExit: Bool {
        self == .requestedStillRunning
    }
}

/// The kernel's answer to a signal request, as read from `errno`.
enum ProcessSignalDelivery: Equatable, Sendable {
    case delivered
    /// `ESRCH`: the target no longer exists. The requested outcome, a process
    /// that is not running, already holds.
    case noSuchProcess
    case rejected(errno: Int32)
}

/// PID values that must never reach `kill(2)`: 0 signals the caller's own
/// process group, a negative value signals a whole group, and 1 is launchd.
enum ProcessSignalGuard {
    static func isSignalablePID(_ pid: Int32) -> Bool {
        pid > 1
    }

    /// `kill(pid, 0)` succeeds for a zombie, which has already exited and only
    /// awaits its parent's `waitpid`. When the kernel state can be read, a
    /// zombie is not alive; when it cannot (another user's process), the
    /// signal-based answer stands.
    static func isZombie(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return info.kp_proc.p_stat == UInt8(SZOMB)
    }
}

enum ProcessOperationState: Equatable {
    case idle
    case runningMutation
    case runningRefresh
    case queued
    case coalesced
}
