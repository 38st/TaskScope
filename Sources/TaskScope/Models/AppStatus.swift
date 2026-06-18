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

struct WatchedProcessSnapshot: Equatable {
    var globalProtect: Bool
    var panGPA: Bool
    var panGPS: Bool

    static let none = WatchedProcessSnapshot(
        globalProtect: false,
        panGPA: false,
        panGPS: false
    )

    var hasHelpers: Bool {
        panGPA || panGPS
    }

    var hasAny: Bool {
        globalProtect || hasHelpers
    }

    var status: ProcessStatus {
        if globalProtect {
            return .watchedRunning
        }

        if hasHelpers {
            return .helpersOnly
        }

        return .idle
    }

    var detail: String {
        var names: [String] = []

        if globalProtect {
            names.append("GlobalProtect")
        }

        if panGPA {
            names.append("PanGPA")
        }

        if panGPS {
            names.append("PanGPS")
        }

        return names.isEmpty ? "No watched processes" : names.joined(separator: ", ")
    }
}

struct AppProcess: Identifiable, Equatable {
    var pid: Int32
    var cpu: Double
    var memory: Double
    var command: String

    var id: Int32 {
        pid
    }

    var name: String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: trimmedCommand).lastPathComponent
        return lastPathComponent.isEmpty ? trimmedCommand : lastPathComponent
    }

    var isWatched: Bool {
        ["GlobalProtect", "PanGPA", "PanGPS"].contains(name)
    }

    var displayCommand: String {
        command.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
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
