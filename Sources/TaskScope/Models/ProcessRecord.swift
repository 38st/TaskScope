import Foundation

struct AppProcess: Identifiable, Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32
    var cpu: Double
    var memoryMB: Double
    var command: String
    /// Kernel-resolved executable vnode path. Never derived from argv/`ps comm`.
    var executablePath: String?
    var elapsedTime: String
    var startTime: String
    var netInKB: Double?
    var netOutKB: Double?
    var diskReadBlocks: Double?
    var diskWriteBlocks: Double?

    init(
        pid: Int32,
        parentPID: Int32,
        cpu: Double,
        memoryMB: Double,
        command: String,
        executablePath: String? = nil,
        elapsedTime: String,
        startTime: String = "",
        netInKB: Double?,
        netOutKB: Double?,
        diskReadBlocks: Double?,
        diskWriteBlocks: Double?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.command = command
        self.executablePath = executablePath
        self.elapsedTime = elapsedTime
        self.startTime = startTime
        self.netInKB = netInKB
        self.netOutKB = netOutKB
        self.diskReadBlocks = diskReadBlocks
        self.diskWriteBlocks = diskWriteBlocks
    }

    var id: Int32 {
        pid
    }

    var name: String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: trimmedCommand).lastPathComponent
        return lastPathComponent.isEmpty ? trimmedCommand : lastPathComponent
    }

    var displayCommand: String {
        (executablePath ?? command).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var identity: ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTime: startTime,
            command: command,
            executablePath: executablePath.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        )
    }

    /// Runtime reported by `ps etime`, whose shape is `[[dd-]hh:]mm:ss`.
    var runtimeSeconds: TimeInterval? {
        let normalizedElapsedTime = elapsedTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedElapsedTime.isEmpty else { return nil }
        let dayAndClock = normalizedElapsedTime.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard dayAndClock.count == 1 || dayAndClock.count == 2 else { return nil }
        let dayCount: Int
        let clock: Substring
        if dayAndClock.count == 2 {
            guard !dayAndClock[0].isEmpty,
                  !dayAndClock[1].isEmpty,
                  let parsedDays = Int(dayAndClock[0]) else { return nil }
            dayCount = parsedDays
            clock = dayAndClock[1]
        } else {
            dayCount = 0
            clock = dayAndClock[0]
        }

        let rawComponents = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard rawComponents.count == 2 || rawComponents.count == 3 else { return nil }
        var components: [Int] = []
        for component in rawComponents {
            guard let value = Int(component), value >= 0 else { return nil }
            components.append(value)
        }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components[components.count - 2]
        let seconds = components[components.count - 1]
        guard dayCount >= 0,
              (dayAndClock.count == 1 || hours < 24),
              minutes < 60,
              seconds < 60 else { return nil }
        let (daySeconds, dayOverflow) = dayCount.multipliedReportingOverflow(by: 86_400)
        let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
        let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
        guard !dayOverflow, !hourOverflow, !minuteOverflow else { return nil }
        let (dayAndHourSeconds, firstAdditionOverflow) = daySeconds.addingReportingOverflow(hourSeconds)
        let (throughMinutes, secondAdditionOverflow) = dayAndHourSeconds.addingReportingOverflow(minuteSeconds)
        let (totalSeconds, finalAdditionOverflow) = throughMinutes.addingReportingOverflow(seconds)
        guard !firstAdditionOverflow, !secondAdditionOverflow, !finalAdditionOverflow else { return nil }
        return TimeInterval(totalSeconds)
    }
}

struct ProcessDetail: Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32
    var user: String
    var startTime: String
    var command: String
}
