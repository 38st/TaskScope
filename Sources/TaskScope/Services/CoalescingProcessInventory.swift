import Foundation

/// Shares a very recent read between non-destructive observers and joins identical
/// reads already in flight. Destructive identity checks use a separate uncached
/// provider so this optimization can never authorize a signal from cached data.
actor CoalescingProcessInventory: ProcessInventoryProviding {
    private struct CachedResult {
        var timestamp: Date
        var includesExtendedStats: Bool
        var result: Result<[AppProcess], ProcessInventoryError>
    }

    private let upstream: any ProcessInventoryProviding
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: CachedResult?
    private var basicTask: Task<Result<[AppProcess], ProcessInventoryError>, Never>?
    private var extendedTask: Task<Result<[AppProcess], ProcessInventoryError>, Never>?

    init(
        upstream: any ProcessInventoryProviding = SystemProcessInventory(),
        maximumAge: TimeInterval = 0.5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.upstream = upstream
        self.maximumAge = max(0, maximumAge)
        self.now = now
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if let cached,
           now().timeIntervalSince(cached.timestamp) <= maximumAge,
           cached.includesExtendedStats || !fetchExtendedStats {
            return cached.result
        }

        if fetchExtendedStats {
            if let extendedTask {
                return await extendedTask.value
            }
            let task = Task { [upstream] in
                await upstream.load(fetchExtendedStats: true)
            }
            extendedTask = task
            let result = await task.value
            extendedTask = nil
            cached = CachedResult(timestamp: now(), includesExtendedStats: true, result: result)
            return result
        }

        if let extendedTask {
            return await extendedTask.value
        }
        if let basicTask {
            return await basicTask.value
        }
        let task = Task { [upstream] in
            await upstream.load(fetchExtendedStats: false)
        }
        basicTask = task
        let result = await task.value
        basicTask = nil
        cached = CachedResult(timestamp: now(), includesExtendedStats: false, result: result)
        return result
    }
}
