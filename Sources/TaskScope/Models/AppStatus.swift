import Foundation

enum ProcessStatus: Equatable {
    case idle
    case helpersOnly
    case protectedOnly
    case watchedRunning

    var title: String {
        switch self {
        case .idle:
            "Quiet"
        case .helpersOnly:
            "Helpers"
        case .protectedOnly:
            "Services"
        case .watchedRunning:
            "Active"
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            "No watched apps running"
        case .helpersOnly:
            "Background helpers running"
        case .protectedOnly:
            "Protected services running"
        case .watchedRunning:
            "Watched app running"
        }
    }

    var menuBarSystemImage: String {
        switch self {
        case .idle:
            "waveform.path.ecg"
        case .helpersOnly:
            "exclamationmark.triangle.fill"
        case .protectedOnly:
            "lock.shield.fill"
        case .watchedRunning:
            "waveform.path.ecg.rectangle.fill"
        }
    }
}

enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case name
    case pid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .name: "Name"
        case .pid: "PID"
        }
    }
}

struct AppProcess: Identifiable, Equatable {
    var pid: Int32
    var parentPID: Int32
    var cpu: Double
    var memoryMB: Double
    var command: String
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
        command.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime, command: command)
    }

    /// Runtime reported by `ps etime`, whose shape is `[[dd-]hh:]mm:ss`.
    var runtimeSeconds: TimeInterval? {
        let dayAndClock = elapsedTime.split(separator: "-", maxSplits: 1)
        let dayCount: Int
        let clock: Substring
        if dayAndClock.count == 2 {
            guard let parsedDays = Int(dayAndClock[0]) else { return nil }
            dayCount = parsedDays
            clock = dayAndClock[1]
        } else {
            dayCount = 0
            clock = dayAndClock[0]
        }

        let components = clock.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components[components.count - 2]
        let seconds = components[components.count - 1]
        guard minutes < 60, seconds < 60 else { return nil }
        return TimeInterval((((dayCount * 24) + hours) * 60 + minutes) * 60 + seconds)
    }
}

struct ProcessIdentity: Hashable, Codable {
    var pid: Int32
    var startTime: String
    var command: String
}

enum ProcessActionResult: Equatable {
    case stopped
    case requestedStillRunning
    case stale
    case rejected

    var succeeded: Bool {
        self == .stopped
    }
}

struct ProcessDetail: Equatable {
    var pid: Int32
    var parentPID: Int32
    var user: String
    var startTime: String
    var command: String
}

struct ShellCommandResult: Equatable {
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int32

    var succeeded: Bool {
        exitCode == 0
    }
}
