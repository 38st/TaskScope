enum ProcessStatus: Equatable, Sendable {
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

enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
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
