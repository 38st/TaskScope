import Foundation

enum ProcessStatus: Equatable {
    case idle
    case helpersOnly
    case watchedRunning

    var title: String {
        switch self {
        case .idle:
            "Quiet"
        case .helpersOnly:
            "Helpers"
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
    var cpu: Double
    var memoryMB: Double
    var command: String

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
