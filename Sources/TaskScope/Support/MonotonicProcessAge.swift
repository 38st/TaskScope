import Darwin
import Foundation

/// Kernel clocks that wall-clock changes cannot move, in nanoseconds.
/// `uptime` follows `mach_absolute_time`, which stops while the Mac sleeps;
/// `asleep` is the total time asleep since boot.
struct UptimeSample: Equatable, Sendable {
    var uptime: UInt64
    var asleep: UInt64

    static func now() -> UptimeSample {
        // No public call reads both clocks together. Reading the clock that
        // includes sleep first can only understate the sleep total. A failed
        // conversion reads as zero, which makes no process look older.
        let continuous = mach_continuous_time()
        let absolute = mach_absolute_time()
        return UptimeSample(
            uptime: nanoseconds(fromMachTime: absolute) ?? 0,
            asleep: nanoseconds(fromMachTime: continuous > absolute ? continuous - absolute : 0) ?? 0
        )
    }

    /// Converts `mach_absolute_time` units to nanoseconds; nil on overflow.
    static func nanoseconds(fromMachTime ticks: UInt64) -> UInt64? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else { return nil }
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }
}

/// Lower-bounds how long a process has existed with kernel clocks that
/// wall-clock changes cannot move.
///
/// `ps etime` subtracts the start time from the current wall clock, so a
/// forward clock step makes processes look older than they are. The kernel's
/// uptime clock at process start cannot be stepped, but it stops while the Mac
/// sleeps. Sleep is added back only when TaskScope observed it after the
/// process had started, so unobserved sleep can delay a runtime rule but never
/// advance it.
struct ProcessAgeHistory {
    private struct Observation {
        /// The latest uptime at which `asleep` was still the sleep total.
        var lastUptime: UInt64
        var asleep: UInt64
    }

    private var observations: [Observation] = []
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    mutating func record(_ sample: UptimeSample) {
        if let last = observations.last, sample.asleep <= last.asleep {
            // Same sleep period; a read can understate the total slightly.
            observations[observations.count - 1].lastUptime = max(last.lastUptime, sample.uptime)
            return
        }
        observations.append(Observation(lastUptime: sample.uptime, asleep: sample.asleep))
        if observations.count > limit {
            // Forgetting old periods can only make earlier processes look younger.
            observations.removeFirst(observations.count - limit)
        }
    }

    /// Seconds a process that started at uptime `start` (nanoseconds) has
    /// certainly existed at `sample`, or nil when `start` is after `sample`.
    func minimumAge(sinceUptime start: UInt64, at sample: UptimeSample) -> TimeInterval? {
        guard start <= sample.uptime else { return nil }
        // A process that started before an observation had slept at most that
        // observation's total when it started. Uptime does not advance during
        // sleep, so a start at an observation's uptime gets no credit for it.
        let asleepAtStart = observations.first { $0.lastUptime > start }?.asleep ?? sample.asleep
        let observedSleep = sample.asleep > asleepAtStart ? sample.asleep - asleepAtStart : 0
        let (age, overflow) = (sample.uptime - start).addingReportingOverflow(observedSleep)
        return overflow ? nil : TimeInterval(age) / 1_000_000_000
    }
}
