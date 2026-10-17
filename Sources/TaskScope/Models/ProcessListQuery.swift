import Darwin
import Foundation

enum ProcessFilterMode: String, CaseIterable, Identifiable {
    case all
    case watched
    case highlighted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .watched: "Watched"
        case .highlighted: "Hot"
        }
    }
}

/// One watched preset's process boundary, mirroring `WatchedSnapshotBuilder`:
/// current-user main processes count inside Contents/MacOS and helpers inside
/// Contents, matched by command or executable name; protected names match by
/// name across users.
struct WatchedProcessScope: Hashable {
    var bundleContentsDirectory: String
    var mainExecutableDirectory: String
    var mainProcessName: String
    var helperNames: Set<String>
    var protectedNames: Set<String>
    var currentUID: uid_t

    init(preset: WatchedAppPreset) {
        self.init(preset: preset, currentUID: getuid())
    }

    init(preset: WatchedAppPreset, currentUID: uid_t) {
        bundleContentsDirectory = preset.bundleContentsDirectory
        mainExecutableDirectory = preset.mainExecutableDirectory
        mainProcessName = preset.mainProcessName
        helperNames = Set(preset.helperProcessNames)
        protectedNames = Set(preset.protectedProcessNames)
        self.currentUID = currentUID
    }

    func contains(_ process: AppProcess) -> Bool {
        if protectedNames.contains(process.name) { return true }
        guard process.uid == currentUID,
              let executablePath = process.executablePath,
              executablePath.hasPrefix(bundleContentsDirectory) else {
            return false
        }
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
        if helperNames.contains(process.name) || helperNames.contains(executableName) { return true }
        return executablePath.hasPrefix(mainExecutableDirectory)
            && (process.name == mainProcessName || executableName == mainProcessName)
    }
}

struct ProcessListQuery: Hashable {
    var searchText: String
    var filterMode: ProcessFilterMode
    var watchedScopes: [WatchedProcessScope]
    var cpuHighlightThreshold: Double
    var memoryHighlightThresholdMB: Double

    func matches(_ process: AppProcess) -> Bool {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = search.isEmpty
            || process.name.localizedCaseInsensitiveContains(search)
            || process.command.localizedCaseInsensitiveContains(search)
            || String(process.pid).contains(search)
        guard matchesSearch else { return false }

        switch filterMode {
        case .all:
            return true
        case .watched:
            return watchedScopes.contains { $0.contains(process) }
        case .highlighted:
            return process.cpu >= cpuHighlightThreshold
                || process.memoryMB >= memoryHighlightThresholdMB
        }
    }
}
