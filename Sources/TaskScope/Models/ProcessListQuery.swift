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

struct ProcessListQuery {
    var searchText: String
    var filterMode: ProcessFilterMode
    var watchedNames: Set<String>
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
            return watchedNames.contains(process.name)
        case .highlighted:
            return process.cpu >= cpuHighlightThreshold
                || process.memoryMB >= memoryHighlightThresholdMB
        }
    }
}
