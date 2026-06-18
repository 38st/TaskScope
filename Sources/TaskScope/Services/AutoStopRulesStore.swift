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

    private let key = "TaskScope.autoStopRules.v1"
    private var tracked: [String: Date] = [:]

    init() {
        rules = Self.load(key: key) ?? []
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
        let now = Date()
        let runningNames = Set(runningProcesses.map { $0.name })

        for process in runningProcesses {
            guard let rule = rules.first(where: { $0.processName.caseInsensitiveCompare(process.name) == .orderedSame }) else {
                tracked.removeValue(forKey: process.name)
                continue
            }

            let firstSeen = tracked[process.name] ?? now
            tracked[process.name] = firstSeen

            let elapsed = now.timeIntervalSince(firstSeen) / 60.0
            if elapsed >= Double(rule.runtimeMinutes) {
                onAction(rule, process)
                tracked.removeValue(forKey: process.name)
            }
        }

        let stale = tracked.keys.filter { !runningNames.contains($0) }
        for name in stale {
            tracked.removeValue(forKey: name)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(key: String) -> [AutoStopRule]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([AutoStopRule].self, from: data)
    }
}
