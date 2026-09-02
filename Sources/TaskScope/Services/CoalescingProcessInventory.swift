import Foundation

/// Shares a very recent read between non-destructive observers and joins identical
/// reads already in flight. Destructive identity checks use a separate uncached
/// provider so this optimization can never authorize a signal from cached data.
///
/// Only successful reads are cached, and a read is cached only if it *started*
/// no earlier than the read that produced the current cache entry, so a slow
/// read that finishes late can never replace a newer result.
actor CoalescingProcessInventory: ProcessInventoryProviding {
    private struct CachedResult {
        var startedAt: Date
        var includesExtendedStats: Bool
        var processes: [AppProcess]
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
           now().timeIntervalSince(cached.startedAt) <= maximumAge,
           cached.includesExtendedStats || !fetchExtendedStats {
            return .success(cached.processes)
        }

        if fetchExtendedStats {
            if let extendedTask {
                return await extendedTask.value
            }
            let startedAt = now()
            let task = Task { [upstream] in
                await upstream.load(fetchExtendedStats: true)
            }
            extendedTask = task
            let result = await task.value
            extendedTask = nil
            store(result, startedAt: startedAt, includesExtendedStats: true)
            return result
        }

        if let extendedTask {
            return await extendedTask.value
        }
        if let basicTask {
            return await basicTask.value
        }
        let startedAt = now()
        let task = Task { [upstream] in
            await upstream.load(fetchExtendedStats: false)
        }
        basicTask = task
        let result = await task.value
        basicTask = nil
        store(result, startedAt: startedAt, includesExtendedStats: false)
        return result
    }

    private func store(
        _ result: Result<[AppProcess], ProcessInventoryError>,
        startedAt: Date,
        includesExtendedStats: Bool
    ) {
        guard case .success(let processes) = result else { return }
        if let cached, cached.startedAt > startedAt { return }
        cached = CachedResult(
            startedAt: startedAt,
            includesExtendedStats: includesExtendedStats,
            processes: processes
        )
    }
}
