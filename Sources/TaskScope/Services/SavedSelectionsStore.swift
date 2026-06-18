import Foundation

@MainActor
final class SavedSelectionsStore: ObservableObject {
    struct SavedSelection: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var pids: [Int32]
    }

    @Published var selections: [SavedSelection] {
        didSet { save() }
    }

    private let key = "TaskScope.savedSelections.v1"

    init() {
        selections = Self.load(key: key) ?? []
    }

    func save(name: String, pids: [Int32]) {
        selections.append(SavedSelection(name: name, pids: pids))
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
