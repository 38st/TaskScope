import AppIntents
import Foundation

@available(macOS 13.0, *)
struct WatchedPresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Watched App")
    static let defaultQuery = WatchedPresetEntityQuery()

    let id: UUID
    let displayName: String

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(preset: WatchedAppPreset) {
        self.init(id: preset.id, displayName: preset.displayName)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct WatchedPresetCatalog: Sendable {
    private let suiteName: String?
    private let key: String

    init(
        suiteName: String? = nil,
        key: String = WatchedAppsStore.defaultPersistenceKey
    ) {
        self.suiteName = suiteName
        self.key = key
    }

    func entities() -> [WatchedPresetEntity] {
        let userDefaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let presets: [WatchedAppPreset]
        if let data = userDefaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WatchedAppPreset].self, from: data) {
            presets = WatchedAppsStore.validatedPresets(decoded).presets
        } else if userDefaults.data(forKey: key) == nil {
            presets = [.globalProtect]
        } else {
            // Match WatchedAppsStore's corruption policy: do not silently replace
            // unreadable user data with a default automation target.
            presets = []
        }

        return presets.map(WatchedPresetEntity.init(preset:))
    }
}

@available(macOS 13.0, *)
struct WatchedPresetEntityQuery: EntityStringQuery {
    private let catalog: WatchedPresetCatalog

    init() {
        catalog = WatchedPresetCatalog()
    }

    init(catalog: WatchedPresetCatalog) {
        self.catalog = catalog
    }

    func entities(for identifiers: [WatchedPresetEntity.ID]) async throws -> [WatchedPresetEntity] {
        let requested = Set(identifiers)
        return catalog.entities().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WatchedPresetEntity] {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return catalog.entities() }
        return catalog.entities().filter {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
        }
    }

    func suggestedEntities() async throws -> [WatchedPresetEntity] {
        catalog.entities()
    }
}

@available(macOS 13.0, *)
enum TaskScopeIntentDialog {
    enum CommandError: LocalizedError {
        case rejected(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message), .failed(let message):
                message
            }
        }
    }

    static func message(
        for result: TaskScopeCommandResult,
        action: String
    ) -> String {
        switch result.status {
        case .completed:
            return result.message
        case .rejected:
            return "Couldn’t \(action): \(result.message)"
        case .failed:
            return "Failed to \(action): \(result.message)"
        }
    }

    static func successMessage(
        for result: TaskScopeCommandResult,
        action: String
    ) throws -> String {
        switch result.status {
        case .completed:
            return result.message
        case .rejected:
            throw CommandError.rejected("Couldn’t \(action): \(result.message)")
        case .failed:
            throw CommandError.failed("Failed to \(action): \(result.message)")
        }
    }
}

@available(macOS 13.0, *)
struct StopWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Watched App"
    static let description = IntentDescription("Stop a watched app using TaskScope's managed lifecycle.")

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.stopPreset(app.displayName))
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "stop \(app.displayName)"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(macOS 13.0, *)
struct OpenWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Watched App"
    static let description = IntentDescription("Open a watched app using TaskScope's managed lifecycle.")

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.openPreset(app.displayName))
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "open \(app.displayName)"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(macOS 13.0, *)
struct RefreshTaskScopeIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh TaskScope"
    static let description = IntentDescription("Request TaskScope to refresh its watched status.")

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppCommandBus.shared.submit(.refresh)
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "refresh TaskScope"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(macOS 13.0, *)
struct TaskScopeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshTaskScopeIntent(),
            phrases: ["Refresh \(.applicationName)"],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StopWatchedAppIntent(),
            phrases: ["Stop \(\.$app) in \(.applicationName)"],
            shortTitle: "Stop Watched App",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: OpenWatchedAppIntent(),
            phrases: ["Open \(\.$app) in \(.applicationName)"],
            shortTitle: "Open Watched App",
            systemImageName: "arrow.up.forward.app"
        )
    }
}
