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
/// main and helper names count only inside the preset's app bundle, matched by
/// command name or executable file name; protected names match by name.
struct WatchedProcessScope: Hashable {
    var bundleContentsDirectory: String
    var processNames: Set<String>
    var protectedNames: Set<String>

    init(preset: WatchedAppPreset) {
        bundleContentsDirectory = preset.bundleContentsDirectory
        processNames = Set([preset.mainProcessName] + preset.helperProcessNames)
        protectedNames = Set(preset.protectedProcessNames)
    }

    func contains(_ process: AppProcess) -> Bool {
        if protectedNames.contains(process.name) { return true }
        guard let executablePath = process.executablePath,
              executablePath.hasPrefix(bundleContentsDirectory) else {
            return false
        }
        return processNames.contains(process.name)
            || processNames.contains(URL(fileURLWithPath: executablePath).lastPathComponent)
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
