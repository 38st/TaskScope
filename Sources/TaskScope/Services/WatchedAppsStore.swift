import Foundation

@MainActor
final class WatchedAppsStore: ObservableObject {
    @Published var presets: [WatchedAppPreset] {
        didSet { save() }
    }

    private let key = "TaskScope.watchedPresets.v1"

    init() {
        presets = Self.load(key: key) ?? [.globalProtect]
    }

    func add(_ preset: WatchedAppPreset) {
        presets.append(preset)
    }

    func remove(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
    }

    func remove(_ preset: WatchedAppPreset) {
        presets.removeAll { $0.id == preset.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
    }

    func update(_ preset: WatchedAppPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load(key: String) -> [WatchedAppPreset]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([WatchedAppPreset].self, from: data)
    }
}
