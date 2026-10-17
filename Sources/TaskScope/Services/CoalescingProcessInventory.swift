import Darwin
import Foundation

/// Shares a very recent read between non-destructive observers and joins identical
/// reads already in flight. Cache age and ordering use monotonic time, including
/// system sleep. Destructive identity checks use a separate uncached
/// provider so this optimization can never authorize a signal from cached data.
///
/// Only successful reads are cached, and a read is cached only if it *started*
/// no earlier than the read that produced the current cache entry, so a slow
/// read that finishes late can never replace a newer result.
actor CoalescingProcessInventory: ProcessInventoryProviding {
    private struct CachedResult {
        var startedAt: TimeInterval
        var includesExtendedStats: Bool
        var processes: [AppProcess]
    }

    private let upstream: any ProcessInventoryProviding
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var cached: CachedResult?
    private var basicTask: Task<Result<[AppProcess], ProcessInventoryError>, Never>?
    private var extendedTask: Task<Result<[AppProcess], ProcessInventoryError>, Never>?
    /// Advanced by `invalidate()`. A read that started under an older
    /// generation is neither cached nor joined by later callers.
    private var generation = 0

    init(
        upstream: any ProcessInventoryProviding = SystemProcessInventory(),
        maximumAge: TimeInterval = 0.5,
        now: @escaping @Sendable () -> TimeInterval = {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        }
    ) {
        self.upstream = upstream
        self.maximumAge = max(0, maximumAge)
        self.now = now
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if let cached {
            let age = now() - cached.startedAt
            if age < 0 {
                // Defensively expire a discontinuous injected clock, including
                // in-flight reads that could otherwise restore the old epoch.
                invalidate()
            } else if age <= maximumAge,
                      cached.includesExtendedStats || !fetchExtendedStats {
                return .success(cached.processes)
            }
        }

        if fetchExtendedStats {
            if let extendedTask {
                return await extendedTask.value
            }
            let startedAt = now()
            let startedGeneration = generation
            let task = Task { [upstream] in
                await upstream.load(fetchExtendedStats: true)
            }
            extendedTask = task
            let result = await task.value
            if extendedTask == task { extendedTask = nil }
            store(result, startedAt: startedAt, generation: startedGeneration, includesExtendedStats: true)
            return result
        }

        if let extendedTask {
            return await extendedTask.value
        }
        if let basicTask {
            return await basicTask.value
        }
        let startedAt = now()
        let startedGeneration = generation
        let task = Task { [upstream] in
            await upstream.load(fetchExtendedStats: false)
        }
        basicTask = task
        let result = await task.value
        if basicTask == task { basicTask = nil }
        store(result, startedAt: startedAt, generation: startedGeneration, includesExtendedStats: false)
        return result
    }

    /// Discards the cached read and detaches in-flight reads after a mutation,
    /// so an observer cannot be served a list taken before a process was
    /// stopped or started.
    func invalidate() {
        generation &+= 1
        cached = nil
        basicTask = nil
        extendedTask = nil
    }

    private func store(
        _ result: Result<[AppProcess], ProcessInventoryError>,
        startedAt: TimeInterval,
        generation startedGeneration: Int,
        includesExtendedStats: Bool
    ) {
        guard startedGeneration == generation else { return }
        guard case .success(let processes) = result else { return }
        if let cached, cached.startedAt > startedAt { return }
        cached = CachedResult(
            startedAt: startedAt,
            includesExtendedStats: includesExtendedStats,
            processes: processes
        )
    }
}
