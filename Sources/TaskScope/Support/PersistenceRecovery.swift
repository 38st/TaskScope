import Foundation

enum PersistenceRecovery {
    /// Recovery slots preserve the oldest known unreadable or rejected payload.
    /// Repeated launches must never replace the only surviving original bytes.
    static func preserveFirstBackup(
        _ data: Data,
        in userDefaults: UserDefaults,
        key: String
    ) {
        guard userDefaults.data(forKey: key) == nil else { return }
        userDefaults.set(data, forKey: key)
    }
}

struct RecoveringCodableStorage<Value: Codable> {
    let userDefaults: UserDefaults
    let key: String

    func load() -> (value: Value?, backupKey: String?) {
        guard let data = userDefaults.data(forKey: key) else {
            return (nil, nil)
        }
        do {
            return (try JSONDecoder().decode(Value.self, from: data), nil)
        } catch {
            let backupKey = "\(key).corruptBackup"
            PersistenceRecovery.preserveFirstBackup(data, in: userDefaults, key: backupKey)
            return (nil, backupKey)
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

    func preserveCurrentPayload(suffix: String) -> String? {
        guard let data = rawData else { return nil }
        let backupKey = "\(key).\(suffix)"
        PersistenceRecovery.preserveFirstBackup(data, in: userDefaults, key: backupKey)
        return backupKey
    }
}
