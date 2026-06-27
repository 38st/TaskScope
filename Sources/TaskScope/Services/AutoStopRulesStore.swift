import Foundation

struct AutoStopRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var processName: String
    var runtimeMinutes: Int
    var action: Action

    enum Action: String, Codable, CaseIterable, Identifiable {
        case prompt
        case kill
        case silent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .prompt: "Prompt"
            case .kill: "Auto Stop"
            case .silent: "Log Only"
            }
        }
    }
}

@MainActor
final class AutoStopRulesStore: ObservableObject {
    @Published var rules: [AutoStopRule] {
        didSet { save() }
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private var tracked: [Int32: Date] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.autoStopRules.v1",
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.now = now
        rules = Self.load(userDefaults: userDefaults, key: key) ?? []
    }

    func add(_ rule: AutoStopRule) {
        rules.append(rule)
    }

    func remove(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    func remove(_ rule: AutoStopRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func evaluate(runningProcesses: [AppProcess], onAction: @escaping (AutoStopRule, AppProcess) -> Void) {
        let now = now()
        let runningPids = Set(runningProcesses.map { $0.pid })

        for process in runningProcesses {
            guard let rule = rules.first(where: { $0.processName.caseInsensitiveCompare(process.name) == .orderedSame }) else {
                tracked.removeValue(forKey: process.pid)
                continue
            }

            let firstSeen = tracked[process.pid] ?? now
            tracked[process.pid] = firstSeen

            let elapsed = now.timeIntervalSince(firstSeen) / 60.0
            if elapsed >= Double(rule.runtimeMinutes) {
                onAction(rule, process)
                tracked.removeValue(forKey: process.pid)
            }
        }

        let stale = tracked.keys.filter { !runningPids.contains($0) }
        for pid in stale {
            tracked.removeValue(forKey: pid)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: key)
        }
    }

    private static func load(userDefaults: UserDefaults, key: String) -> [AutoStopRule]? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([AutoStopRule].self, from: data)
    }
}
