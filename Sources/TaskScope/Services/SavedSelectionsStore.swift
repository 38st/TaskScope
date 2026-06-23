import Foundation

@MainActor
final class SavedSelectionsStore: ObservableObject {
    struct SavedProcess: Codable, Equatable {
        var pid: Int32
        var command: String
    }

    struct SavedSelection: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var pids: [Int32]
        var processes: [SavedProcess]?

        func matches(_ process: AppProcess) -> Bool {
            guard let processes, !processes.isEmpty else { return false }
            return processes.contains {
                $0.pid == process.pid && $0.command == process.command
            }
        }
    }

    @Published var selections: [SavedSelection] {
        didSet { save() }
    }

    private let key = "TaskScope.savedSelections.v1"

    init() {
        selections = Self.load(key: key) ?? []
    }

    func save(name: String, processes: [AppProcess]) {
        selections.append(
            SavedSelection(
                name: name,
                pids: processes.map { $0.pid },
                processes: processes.map { SavedProcess(pid: $0.pid, command: $0.command) }
            )
        )
    }

    func remove(at offsets: IndexSet) {
        selections.remove(atOffsets: offsets)
    }

    func remove(_ selection: SavedSelection) {
        selections.removeAll { $0.id == selection.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(selections) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(key: String) -> [SavedSelection]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([SavedSelection].self, from: data)
    }
}
