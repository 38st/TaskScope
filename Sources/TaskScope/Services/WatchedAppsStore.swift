import Foundation

@MainActor
final class WatchedAppsStore: ObservableObject {
    struct ImportResult: Equatable {
        var importedCount: Int
        var rejectedCount: Int
    }

    nonisolated static let defaultPersistenceKey = "TaskScope.watchedPresets.v1"

    @Published private(set) var presets: [WatchedAppPreset] {
        didSet { persistIfAllowed() }
    }
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var validationError: String?

    private let userDefaults: UserDefaults
    private let key: String
    private var allowsPersistence: Bool
    private var recoveredDecodedPayload: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = WatchedAppsStore.defaultPersistenceKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
        guard let data = userDefaults.data(forKey: key) else {
            presets = [.globalProtect]
            allowsPersistence = true
            recoveredDecodedPayload = false
            // Assigning in `init` does not fire `didSet`, so the seeded default was
            // never written. Persist it now so the preset the App Intents catalog
            // publishes is backed by stored bytes and keeps one identity.
            persistIfAllowed()
            return
        }

        do {
            let decoded = try JSONDecoder().decode([WatchedAppPreset].self, from: data)
            let validated = Self.validatedPresets(decoded)
            presets = validated.presets
            if validated.rejectedCount > 0 {
                let backupKey = "\(key).rejectedMigrationBackup"
                Self.preserveFirstBackup(
                    data,
                    userDefaults: userDefaults,
                    backupKey: backupKey
                )
                allowsPersistence = false
                recoveredDecodedPayload = true
                persistenceIssue = "Rejected \(validated.rejectedCount) unsafe or invalid stored preset\(validated.rejectedCount == 1 ? "" : "s"). The first rejected payload is preserved as \(backupKey); review or export the recovered presets, then reset to commit them."
            } else {
                allowsPersistence = true
                recoveredDecodedPayload = false
            }
        } catch {
            let backupKey = "\(key).corruptBackup"
            Self.preserveFirstBackup(
                data,
                userDefaults: userDefaults,
                backupKey: backupKey
            )
            presets = []
            allowsPersistence = false
            recoveredDecodedPayload = false
            persistenceIssue = "Preset data was unreadable. The first unreadable payload is preserved as \(backupKey), and the current primary remains untouched until reset."
        }
    }

    /// True once a decode failure has disabled writing. Callers must treat a
    /// mutation as unsuccessful in this state rather than reporting a save that
    /// cannot reach disk.
    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// Safe recovered presets from a decoded payload may be exported for review even
    /// though persistence stays locked. A payload that could not be decoded has no
    /// trustworthy in-memory representation to export.
    var canExportPresets: Bool {
        allowsPersistence || recoveredDecodedPayload
    }

    private func rejectIfReadOnly() -> Bool {
        guard !allowsPersistence else { return false }
        validationError = "Preset data is in recovery mode; reset presets before making changes."
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

    @discardableResult
    func remove(at offsets: IndexSet) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.remove(atOffsets: offsets)
        return true
    }

    @discardableResult
    func remove(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.removeAll { $0.id == preset.id }
        return true
    }

    @discardableResult
    func move(from source: IndexSet, to destination: Int) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.move(fromOffsets: source, toOffset: destination)
        return true
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

    /// Explicitly accepts the safe recovered presets and resumes writing. A payload
    /// that could not be decoded has no recoverable entries, so it resets to the
    /// built-in default; a decoded payload rejected by newer validation commits only
    /// the entries that passed current validation.
    func resetAfterCorruption() {
        guard !allowsPersistence else { return }
        allowsPersistence = true
        recoveredDecodedPayload = false
        if presets.isEmpty {
            presets = [.globalProtect]
        } else {
            persistIfAllowed()
        }
        persistenceIssue = nil
        validationError = nil
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
        let result = Self.validateAndNormalizePreset(preset)
        validationError = result.error
        return result.preset
    }

    nonisolated static func validatedPresets(
        _ candidates: [WatchedAppPreset]
    ) -> (presets: [WatchedAppPreset], rejectedCount: Int) {
        var accepted: [WatchedAppPreset] = []
        var seenIDs: Set<UUID> = []
        var semanticKeys: Set<String> = []
        var rejected = 0

        for candidate in candidates {
            guard let preset = validateAndNormalizePreset(candidate).preset else {
                rejected += 1
                continue
            }
            let keys = [preset.displayName, preset.mainProcessName, preset.appPath]
                .map { $0.lowercased() }
            guard seenIDs.insert(preset.id).inserted,
                  semanticKeys.isDisjoint(with: keys) else {
                rejected += 1
                continue
            }
            semanticKeys.formUnion(keys)
            accepted.append(preset)
        }
        return (accepted, rejected)
    }

    nonisolated private static func validateAndNormalizePreset(
        _ preset: WatchedAppPreset
    ) -> (preset: WatchedAppPreset?, error: String?) {
        var value = preset
        value.displayName = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mainProcessName = value.mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.helperProcessNames = normalizedNames(value.helperProcessNames)
        value.protectedProcessNames = normalizedNames(value.protectedProcessNames)
        value.appPath = value.appPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.displayName.isEmpty, !value.mainProcessName.isEmpty else {
            return (nil, "Display name and main process name are required.")
        }
        guard value.appPath.hasPrefix("/"),
              URL(fileURLWithPath: value.appPath).pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return (nil, "App path must be an absolute .app bundle path.")
        }
        let killable = Set(([value.mainProcessName] + value.helperProcessNames).map { $0.lowercased() })
        let protected = Set(value.protectedProcessNames.map { $0.lowercased() })
        guard killable.isDisjoint(with: protected) else {
            return (nil, "Protected process names cannot also be main or helper process names.")
        }
        if value.id == WatchedAppPreset.globalProtectID {
            guard value.hasCanonicalGlobalProtectIdentity else {
                return (nil, "The built-in GlobalProtect lifecycle identity cannot be modified.")
            }
        } else if !value.systemLaunchDaemonJobs.isEmpty {
            return (nil, "Custom presets cannot configure privileged system launch daemons.")
        }
        guard let jobsError = jobsValidationError(value) else {
            return (value, nil)
        }
        return (nil, jobsError)
    }

    nonisolated private static func jobsValidationError(_ preset: WatchedAppPreset) -> String? {
        for job in preset.userLaunchAgentJobs {
            guard !job.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension == "plist" else {
                return "Every launch agent requires a label and absolute .plist path."
            }
        }
        for job in preset.systemLaunchDaemonJobs {
            guard !job.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !job.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension == "plist",
                  job.servicePort.map({ (1...65_535).contains($0) }) ?? true else {
                return "Every daemon requires valid label, process, plist path, and optional port."
            }
        }
        return nil
    }

    nonisolated private static func normalizedNames(_ names: [String]) -> [String] {
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

    nonisolated private static func preserveFirstBackup(
        _ data: Data,
        userDefaults: UserDefaults,
        backupKey: String
    ) {
        if userDefaults.data(forKey: backupKey) == nil {
            userDefaults.set(data, forKey: backupKey)
        }
    }
}
