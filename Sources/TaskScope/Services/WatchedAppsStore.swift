import Foundation

@MainActor
final class WatchedAppsStore: ObservableObject {
    struct ImportResult: Equatable {
        var importedCount: Int
        var rejectedCount: Int
    }

    nonisolated static let defaultPersistenceKey = "TaskScope.watchedPresets.v1"

    @Published var presets: [WatchedAppPreset] {
        didSet { persistIfAllowed() }
    }
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var validationError: String?

    private let userDefaults: UserDefaults
    private let key: String
    private var allowsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = WatchedAppsStore.defaultPersistenceKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        guard let data = userDefaults.data(forKey: key) else {
            presets = [.globalProtect]
            allowsPersistence = true
            // Assigning in `init` does not fire `didSet`, so the seeded default was
            // never written. Persist it now so the preset the App Intents catalog
            // publishes is backed by stored bytes and keeps one identity.
            persistIfAllowed()
            return
        }

        do {
            presets = try JSONDecoder().decode([WatchedAppPreset].self, from: data)
            allowsPersistence = true
        } catch {
            let backupKey = "\(key).corruptBackup"
            userDefaults.set(data, forKey: backupKey)
            presets = []
            allowsPersistence = false
            persistenceIssue = "Preset data was unreadable and preserved as \(backupKey). Reset only after exporting or reviewing the backup."
        }
    }

    /// True once a decode failure has disabled writing. Callers must treat a
    /// mutation as unsuccessful in this state rather than reporting a save that
    /// cannot reach disk.
    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    private func rejectIfReadOnly() -> Bool {
        guard !allowsPersistence else { return false }
        validationError = "Preset data is unreadable; reset presets before making changes."
        return true
    }

    @discardableResult
    func add(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized) else {
            return false
        }
        validationError = nil
        presets.append(normalized)
        return true
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

    @discardableResult
    func update(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard let index = presets.firstIndex(where: { $0.id == preset.id }),
              let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized, excluding: preset.id) else {
            return false
        }
        validationError = nil
        presets[index] = normalized
        return true
    }

    /// Discards the unreadable payload and resumes writing. Anything the user
    /// rebuilt during the corrupt session is kept — resetting used to replace it
    /// with the default preset, destroying the recovery work.
    func resetAfterCorruption() {
        if presets.isEmpty {
            presets = [.globalProtect]
        }
        allowsPersistence = true
        persistenceIssue = nil
        validationError = nil
        persistIfAllowed()
    }

    func importPresets(_ candidates: [WatchedAppPreset]) -> ImportResult {
        var seenIDs = Set(presets.map(\.id))
        var imported = 0
        var rejected = 0

        for preset in candidates {
            guard seenIDs.insert(preset.id).inserted, add(preset) else {
                rejected += 1
                continue
            }
            imported += 1
        }

        return ImportResult(importedCount: imported, rejectedCount: rejected)
    }

    private func validateAndNormalize(_ preset: WatchedAppPreset) -> WatchedAppPreset? {
        var value = preset
        value.displayName = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mainProcessName = value.mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.helperProcessNames = normalizedNames(value.helperProcessNames)
        value.protectedProcessNames = normalizedNames(value.protectedProcessNames)
        value.appPath = value.appPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.displayName.isEmpty, !value.mainProcessName.isEmpty else {
            validationError = "Display name and main process name are required."
            return nil
        }
        guard value.appPath.hasPrefix("/"),
              URL(fileURLWithPath: value.appPath).pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            validationError = "App path must be an absolute .app bundle path."
            return nil
        }
        guard jobsAreValid(value) else { return nil }
        return value
    }

    private func jobsAreValid(_ preset: WatchedAppPreset) -> Bool {
        for job in preset.userLaunchAgentJobs {
            guard !job.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension == "plist" else {
                validationError = "Every launch agent requires a label and absolute .plist path."
                return false
            }
        }
        for job in preset.systemLaunchDaemonJobs {
            guard !job.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !job.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension == "plist",
                  job.servicePort.map({ (1...65_535).contains($0) }) ?? true else {
                validationError = "Every daemon requires valid label, process, plist path, and optional port."
                return false
            }
        }
        return true
    }

    private func normalizedNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    private func isSemanticDuplicate(
        _ preset: WatchedAppPreset,
        excluding id: UUID? = nil
    ) -> Bool {
        let duplicate = presets.contains {
            $0.id != id && (
                $0.displayName.caseInsensitiveCompare(preset.displayName) == .orderedSame
                || $0.mainProcessName.caseInsensitiveCompare(preset.mainProcessName) == .orderedSame
                || $0.appPath.caseInsensitiveCompare(preset.appPath) == .orderedSame
            )
        }
        if duplicate {
            validationError = "A preset with the same name, process, or app path already exists."
        }
        return duplicate
    }

    private func persistIfAllowed() {
        guard allowsPersistence,
              let data = try? JSONEncoder().encode(presets) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}
