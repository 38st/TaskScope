import Foundation

/// Owns the lifetime of a single repeating polling task. Inventory acquisition
/// and presentation decisions remain with the supplied action.
@MainActor
final class ProcessPollingController {
    typealias Sleeper = @Sendable (TimeInterval) async -> Bool

    private let sleep: Sleeper
    private var task: Task<Void, Never>?

    init() {
        sleep = { interval in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(interval * 1_000_000_000)
                )
                return true
            } catch {
                return false
            }
        }
    }

    init(sleep: @escaping Sleeper) {
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    func restart(
        interval: TimeInterval,
        performImmediately: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) {
        task?.cancel()
        let delay = max(2, interval)
        let sleep = self.sleep
        task = Task { [weak self] in
            if performImmediately {
                await action()
            }
            while !Task.isCancelled {
                guard await sleep(delay), !Task.isCancelled else { break }
                guard self != nil else { break }
                await action()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
