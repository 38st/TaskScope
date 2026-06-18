import Foundation

struct WatchedAppPreset: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var mainProcessName: String
    var helperProcessNames: [String]
    var protectedProcessNames: [String]
    var appPath: String
    var notificationsEnabled: Bool = true
    var priority: Int = 0

    var allProcessNames: [String] {
        [mainProcessName] + helperProcessNames + protectedProcessNames
    }

    var killableNames: [String] {
        [mainProcessName] + helperProcessNames
    }

    static let globalProtect = WatchedAppPreset(
        displayName: "GlobalProtect",
        mainProcessName: "GlobalProtect",
        helperProcessNames: ["PanGPA"],
        protectedProcessNames: ["PanGPS"],
        appPath: "/Applications/GlobalProtect.app"
    )
}

struct WatchedAppSnapshot: Equatable {
    var preset: WatchedAppPreset
    var runningNames: Set<String>

    var isMainRunning: Bool {
        runningNames.contains(preset.mainProcessName)
    }

    var helpersRunning: [String] {
        preset.helperProcessNames.filter { runningNames.contains($0) }
    }

    var protectedRunning: [String] {
        preset.protectedProcessNames.filter { runningNames.contains($0) }
    }

    var hasHelpers: Bool {
        !helpersRunning.isEmpty
    }

    var hasAny: Bool {
        !runningNames.isEmpty
    }

    var detail: String {
        var names: [String] = []
        if isMainRunning {
            names.append(preset.mainProcessName)
        }
        names.append(contentsOf: helpersRunning)
        names.append(contentsOf: protectedRunning)
        return names.isEmpty ? "No watched processes" : names.joined(separator: ", ")
    }
}

extension Array where Element == WatchedAppSnapshot {
    var aggregateStatus: ProcessStatus {
        if contains(where: { $0.isMainRunning }) {
            return .watchedRunning
        }
        if contains(where: { $0.hasHelpers }) {
            return .helpersOnly
        }
        return .idle
    }

    var aggregateDetail: String {
        let running = compactMap { snap -> String? in
            guard snap.hasAny else { return nil }
            return snap.detail
        }
        return running.isEmpty ? "No watched processes" : running.joined(separator: " · ")
    }
}
