import Foundation

enum PersistenceRecovery {
    /// Recovery slots preserve the oldest known unreadable or rejected payload.
    /// Repeated launches must never replace the only surviving original bytes.
    /// Returns whether this call wrote the backup; a `false` means an earlier
    /// payload already occupies the slot and the current one was left in place.
    @discardableResult
    static func preserveFirstBackup(
        _ data: Data,
        in userDefaults: UserDefaults,
        key: String
    ) -> Bool {
        guard userDefaults.data(forKey: key) == nil else { return false }
        userDefaults.set(data, forKey: key)
        return true
    }

    static func unreadableDataMessage(backupKey: String, didWriteBackup: Bool) -> String {
        didWriteBackup
            ? "Unreadable data was backed up as \(backupKey)."
            : "Unreadable data was not backed up: \(backupKey) already preserves an earlier unreadable payload, and the current payload remains at its primary key."
    }
}

struct RecoveringCodableStorage<Value: Codable> {
    struct LoadOutcome {
        var value: Value?
        var backupKey: String?
        /// True only when this load wrote the backup. False with a non-nil
        /// `backupKey` means an earlier backup already occupied the slot.
        var didWriteBackup: Bool
    }

    let userDefaults: UserDefaults
    let key: String

    func load() -> LoadOutcome {
        guard let data = userDefaults.data(forKey: key) else {
            return LoadOutcome(value: nil, backupKey: nil, didWriteBackup: false)
        }
        do {
            return LoadOutcome(
                value: try JSONDecoder().decode(Value.self, from: data),
                backupKey: nil,
                didWriteBackup: false
            )
        } catch {
            let backupKey = "\(key).corruptBackup"
            let didWrite = PersistenceRecovery.preserveFirstBackup(data, in: userDefaults, key: backupKey)
            return LoadOutcome(value: nil, backupKey: backupKey, didWriteBackup: didWrite)
        }
    }

    var rawData: Data? {
        userDefaults.data(forKey: key)
    }

    @discardableResult
    func save(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        userDefaults.set(data, forKey: key)
        return true
    }

    func preserveCurrentPayload(suffix: String) -> (key: String, didWrite: Bool)? {
        guard let data = rawData else { return nil }
        let backupKey = "\(key).\(suffix)"
        let didWrite = PersistenceRecovery.preserveFirstBackup(data, in: userDefaults, key: backupKey)
        return (backupKey, didWrite)
    }
}
