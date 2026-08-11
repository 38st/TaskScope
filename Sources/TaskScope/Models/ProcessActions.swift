enum ProcessActionResult: Equatable, Sendable {
    case stopped
    case requestedStillRunning
    case stale
    case rejected

    var succeeded: Bool {
        self == .stopped
    }
}

enum ProcessOperationState: Equatable {
    case idle
    case runningMutation
    case runningRefresh
    case queued
    case coalesced
}
