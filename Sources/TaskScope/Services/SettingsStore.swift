import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var refreshIntervalSeconds: Double {
        didSet { normalizeAndSave() }
    }
    @Published var processListLimit: Int {
        didSet { normalizeAndSave() }
    }
    @Published var cpuHighlightThreshold: Double {
        didSet { normalizeAndSave() }
    }
    @Published var memHighlightThresholdMB: Double {
        didSet { normalizeAndSave() }
    }
    @Published var autoRefreshProcessList: Bool {
        didSet { save() }
    }
    @Published var enableNotifications: Bool {
        didSet { save() }
    }
    @Published var selectedSectionRaw: String {
        didSet { normalizeAndSave() }
    }
    @Published var searchText: String {
        didSet { normalizeAndSave() }
    }
    @Published var sortKeyRaw: String {
        didSet { normalizeAndSave() }
    }
    @Published private(set) var recoveryMessage: String?

    private let userDefaults: UserDefaults
    private let key: String
    private var isNormalizing = false
    private var allowsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.settings.v1"
    ) {
        self.userDefaults = userDefaults
        self.key = key
        let result = Self.load(userDefaults: userDefaults, key: key)
        let decoded: CodableSettings
        switch result {
        case .missing:
            decoded = .defaults
            recoveryMessage = nil
            allowsPersistence = true
        case .loaded(let settings):
            decoded = settings.normalized()
            recoveryMessage = nil
            allowsPersistence = true
        case .corrupt(let data):
            decoded = .defaults
            let backupKey = "\(key).corruptBackup"
            if userDefaults.data(forKey: backupKey) == nil {
                userDefaults.set(data, forKey: backupKey)
            }
            recoveryMessage = "Settings were unreadable. The first unreadable payload is preserved as \(backupKey), and the current primary remains untouched until reset."
            allowsPersistence = false
        }

        refreshIntervalSeconds = decoded.refreshIntervalSeconds
        processListLimit = decoded.processListLimit
        cpuHighlightThreshold = decoded.cpuHighlightThreshold
        memHighlightThresholdMB = decoded.memHighlightThresholdMB
        autoRefreshProcessList = decoded.autoRefreshProcessList
        enableNotifications = decoded.enableNotifications
        selectedSectionRaw = decoded.selectedSectionRaw
        searchText = decoded.searchText
        sortKeyRaw = decoded.sortKeyRaw
    }

    var sortKey: ProcessSortKey {
        ProcessSortKey(rawValue: sortKeyRaw) ?? .cpu
    }

    var selectedSection: TaskScopeSection {
        TaskScopeSection(rawValue: selectedSectionRaw) ?? .processes
    }

    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// Explicitly accepts the safe in-memory settings and resumes persistence. Until
    /// this is called, every property may be used by the running app but the unreadable
    /// primary bytes remain untouched.
    func resetAfterCorruption() {
        guard !allowsPersistence else { return }
        allowsPersistence = true
        recoveryMessage = nil
        normalizeAndSave()
    }

    private func normalizeAndSave() {
        guard !isNormalizing else { return }
        let normalized = currentSettings.normalized()
        if normalized != currentSettings {
            isNormalizing = true
            refreshIntervalSeconds = normalized.refreshIntervalSeconds
            processListLimit = normalized.processListLimit
            cpuHighlightThreshold = normalized.cpuHighlightThreshold
            memHighlightThresholdMB = normalized.memHighlightThresholdMB
            selectedSectionRaw = normalized.selectedSectionRaw
            searchText = normalized.searchText
            sortKeyRaw = normalized.sortKeyRaw
            isNormalizing = false
        }
        save()
    }

    private var currentSettings: CodableSettings {
        CodableSettings(
            schemaVersion: CodableSettings.currentSchemaVersion,
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
    }

    private func save() {
        guard allowsPersistence,
              !isNormalizing,
              let data = try? JSONEncoder().encode(currentSettings.normalized()) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    private enum LoadResult {
        case missing
        case loaded(CodableSettings)
        case corrupt(Data)
    }

    private struct CodableSettings: Codable, Equatable {
        static let currentSchemaVersion = 2
        static let defaults = CodableSettings(
            schemaVersion: currentSchemaVersion,
            refreshIntervalSeconds: 10,
            processListLimit: 80,
            cpuHighlightThreshold: 30,
            memHighlightThresholdMB: 1024,
            autoRefreshProcessList: false,
            enableNotifications: false,
            selectedSectionRaw: TaskScopeSection.processes.rawValue,
            searchText: "",
            sortKeyRaw: ProcessSortKey.cpu.rawValue
        )

        var schemaVersion: Int
        var refreshIntervalSeconds: Double
        var processListLimit: Int
        var cpuHighlightThreshold: Double
        var memHighlightThresholdMB: Double
        var autoRefreshProcessList: Bool
        var enableNotifications: Bool
        var selectedSectionRaw: String
        var searchText: String
        var sortKeyRaw: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case refreshIntervalSeconds
            case processListLimit
            case cpuHighlightThreshold
            case memHighlightThresholdMB
            case autoRefreshProcessList
            case enableNotifications
            case selectedSectionRaw
            case searchText
            case sortKeyRaw
        }

        init(
            schemaVersion: Int,
            refreshIntervalSeconds: Double,
            processListLimit: Int,
            cpuHighlightThreshold: Double,
            memHighlightThresholdMB: Double,
            autoRefreshProcessList: Bool,
            enableNotifications: Bool,
            selectedSectionRaw: String,
            searchText: String,
            sortKeyRaw: String
        ) {
            self.schemaVersion = schemaVersion
            self.refreshIntervalSeconds = refreshIntervalSeconds
            self.processListLimit = processListLimit
            self.cpuHighlightThreshold = cpuHighlightThreshold
            self.memHighlightThresholdMB = memHighlightThresholdMB
            self.autoRefreshProcessList = autoRefreshProcessList
            self.enableNotifications = enableNotifications
            self.selectedSectionRaw = selectedSectionRaw
            self.searchText = searchText
            self.sortKeyRaw = sortKeyRaw
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self.defaults
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            refreshIntervalSeconds = try container.decodeIfPresent(
                Double.self,
                forKey: .refreshIntervalSeconds
            ) ?? defaults.refreshIntervalSeconds
            processListLimit = try container.decodeIfPresent(
                Int.self,
                forKey: .processListLimit
            ) ?? defaults.processListLimit
            cpuHighlightThreshold = try container.decodeIfPresent(
                Double.self,
                forKey: .cpuHighlightThreshold
            ) ?? defaults.cpuHighlightThreshold
            memHighlightThresholdMB = try container.decodeIfPresent(
                Double.self,
                forKey: .memHighlightThresholdMB
            ) ?? defaults.memHighlightThresholdMB
            autoRefreshProcessList = try container.decodeIfPresent(
                Bool.self,
                forKey: .autoRefreshProcessList
            ) ?? defaults.autoRefreshProcessList
            enableNotifications = try container.decodeIfPresent(
                Bool.self,
                forKey: .enableNotifications
            ) ?? defaults.enableNotifications
            selectedSectionRaw = try container.decodeIfPresent(
                String.self,
                forKey: .selectedSectionRaw
            ) ?? defaults.selectedSectionRaw
            searchText = try container.decodeIfPresent(
                String.self,
                forKey: .searchText
            ) ?? defaults.searchText
            sortKeyRaw = try container.decodeIfPresent(
                String.self,
                forKey: .sortKeyRaw
            ) ?? defaults.sortKeyRaw
        }

        func normalized() -> CodableSettings {
            var value = self
            value.schemaVersion = Self.currentSchemaVersion
            value.refreshIntervalSeconds = min(60, max(2, refreshIntervalSeconds))
            value.processListLimit = min(200, max(10, processListLimit))
            value.cpuHighlightThreshold = min(100, max(1, cpuHighlightThreshold))
            value.memHighlightThresholdMB = min(8192, max(100, memHighlightThresholdMB))
            if TaskScopeSection(rawValue: selectedSectionRaw) == nil {
                value.selectedSectionRaw = TaskScopeSection.processes.rawValue
            }
            value.searchText = String(searchText.prefix(500))
            if ProcessSortKey(rawValue: sortKeyRaw) == nil {
                value.sortKeyRaw = ProcessSortKey.cpu.rawValue
            }
            return value
        }
    }

    private static func load(userDefaults: UserDefaults, key: String) -> LoadResult {
        guard let data = userDefaults.data(forKey: key) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(CodableSettings.self, from: data))
        } catch {
            return .corrupt(data)
        }
    }
}
