import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var refreshIntervalSeconds: Double {
        didSet { save() }
    }
    @Published var processListLimit: Int {
        didSet { save() }
    }
    @Published var cpuHighlightThreshold: Double {
        didSet { save() }
    }
    @Published var memHighlightThresholdMB: Double {
        didSet { save() }
    }
    @Published var autoRefreshProcessList: Bool {
        didSet { save() }
    }
    @Published var enableNotifications: Bool {
        didSet { save() }
    }

    @Published var selectedSectionRaw: String {
        didSet { save() }
    }
    @Published var searchText: String {
        didSet { save() }
    }
    @Published var sortKeyRaw: String {
        didSet { save() }
    }

    private let key = "TaskScope.settings.v1"

    init() {
        let decoded = Self.load(key: key)
        refreshIntervalSeconds = decoded?.refreshIntervalSeconds ?? 10
        processListLimit = decoded?.processListLimit ?? 80
        cpuHighlightThreshold = decoded?.cpuHighlightThreshold ?? 30
        memHighlightThresholdMB = decoded?.memHighlightThresholdMB ?? 1024
        autoRefreshProcessList = decoded?.autoRefreshProcessList ?? false
        enableNotifications = decoded?.enableNotifications ?? true
        selectedSectionRaw = decoded?.selectedSectionRaw ?? TaskScopeSection.processes.rawValue
        searchText = decoded?.searchText ?? ""
        sortKeyRaw = decoded?.sortKeyRaw ?? ProcessSortKey.cpu.rawValue
    }

    var sortKey: ProcessSortKey {
        ProcessSortKey(rawValue: sortKeyRaw) ?? .cpu
    }

    var selectedSection: TaskScopeSection {
        TaskScopeSection(rawValue: selectedSectionRaw) ?? .processes
    }

    private func save() {
        let codable = CodableSettings(
            refreshIntervalSeconds: refreshIntervalSeconds,
            processListLimit: processListLimit,
            cpuHighlightThreshold: cpuHighlightThreshold,
            memHighlightThresholdMB: memHighlightThresholdMB,
            autoRefreshProcessList: autoRefreshProcessList,
            enableNotifications: enableNotifications,
            selectedSectionRaw: selectedSectionRaw,
            searchText: searchText,
            sortKeyRaw: sortKeyRaw
        )
        if let data = try? JSONEncoder().encode(codable) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private struct CodableSettings: Codable {
        var refreshIntervalSeconds: Double
        var processListLimit: Int
        var cpuHighlightThreshold: Double
        var memHighlightThresholdMB: Double
        var autoRefreshProcessList: Bool
        var enableNotifications: Bool
        var selectedSectionRaw: String
        var searchText: String
        var sortKeyRaw: String
    }

    private static func load(key: String) -> CodableSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CodableSettings.self, from: data)
    }
}
