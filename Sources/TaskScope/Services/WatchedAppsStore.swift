import Foundation

enum WatchedAppsDefaults {
    private static let key = "TaskScope.watchedPresets.v1"

    static func persistedPresets() -> [WatchedAppPreset] {
        load() ?? [.globalProtect]
    }

    static func save(_ presets: [WatchedAppPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load() -> [WatchedAppPreset]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([WatchedAppPreset].self, from: data)
    }
}

@MainActor
final class WatchedAppsStore: ObservableObject {
    @Published var presets: [WatchedAppPreset] {
        didSet { save() }
    }

    init() {
        presets = WatchedAppsDefaults.persistedPresets()
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
        WatchedAppsDefaults.save(presets)
    }
}
