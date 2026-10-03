import Foundation

enum PersistenceRecovery {
    /// Number of recovery slots per base key: `<base>`, `<base>.2`, … .
    static let maximumBackupSlots = 10

    /// Preserves `data` without ever replacing an earlier backup. The first
    /// slot keeps the oldest payload; a later, different payload goes to the
    /// next free numbered slot so a second corruption is not lost on reset.
    /// Returns the slot that holds these exact bytes, or nil when every slot is
    /// occupied by other payloads and nothing could be preserved.
    static func preserveBackup(
        _ data: Data,
        in userDefaults: UserDefaults,
        baseKey: String
    ) -> String? {
        var firstFreeKey: String?
        for slot in 1...maximumBackupSlots {
            let key = slot == 1 ? baseKey : "\(baseKey).\(slot)"
            guard let existing = userDefaults.data(forKey: key) else {
                if firstFreeKey == nil { firstFreeKey = key }
                continue
            }
            if existing == data { return key }
        }
        guard let firstFreeKey else { return nil }
        userDefaults.set(data, forKey: firstFreeKey)
        return firstFreeKey
    }

    static func unreadableDataMessage(backupKey: String, isPreserved: Bool) -> String {
        isPreserved
            ? "Unreadable data was backed up as \(backupKey)."
            : "Unreadable data was not backed up: every recovery slot starting at \(backupKey) already preserves an earlier payload, and the current payload remains at its primary key."
    }

    static func preservedPayloadDescription(backupKey: String, isPreserved: Bool) -> String {
        isPreserved
            ? "The payload is preserved as \(backupKey)"
            : "The payload could not be backed up because every recovery slot starting at \(backupKey) is occupied"
    }
}

struct PartiallyDecodedArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var rejectedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            do {
                elements.append(try Element(from: elementDecoder))
            } catch {
                rejectedCount += 1
            }
        }
    }
}

struct RecoveringCodableStorage<Value: Codable> {
    struct LoadOutcome {
        var value: Value?
        var backupKey: String?
        /// True when a recovery slot holds these exact bytes, whether this load
        /// wrote it or an earlier launch did. False with a non-nil `backupKey`
        /// means every slot was occupied by other payloads.
        var isBackupPreserved: Bool
        var rejectedCount = 0
    }

    let userDefaults: UserDefaults
    let key: String

    func load(
        decode: (Data) throws -> Value = { try JSONDecoder().decode(Value.self, from: $0) }
    ) -> LoadOutcome {
        guard let data = userDefaults.data(forKey: key) else {
            return LoadOutcome(value: nil, backupKey: nil, isBackupPreserved: false)
        }
        do {
            return LoadOutcome(
                value: try decode(data),
                backupKey: nil,
                isBackupPreserved: false
            )
        } catch {
            let baseKey = "\(key).corruptBackup"
            let preservedKey = PersistenceRecovery.preserveBackup(data, in: userDefaults, baseKey: baseKey)
            return LoadOutcome(
                value: nil,
                backupKey: preservedKey ?? baseKey,
                isBackupPreserved: preservedKey != nil
            )
        }
    }

    func loadRecoveringElements<Element: Codable>() -> LoadOutcome where Value == [Element] {
        var rejectedCount = 0
        var outcome = load { data in
            let decoded = try JSONDecoder().decode(PartiallyDecodedArray<Element>.self, from: data)
            rejectedCount = decoded.rejectedCount
            return decoded.elements
        }
        outcome.rejectedCount = rejectedCount
        return outcome
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

    func preserveCurrentPayload(suffix: String) -> (key: String, isPreserved: Bool)? {
        guard let data = rawData else { return nil }
        let baseKey = "\(key).\(suffix)"
        let preservedKey = PersistenceRecovery.preserveBackup(data, in: userDefaults, baseKey: baseKey)
        return (preservedKey ?? baseKey, preservedKey != nil)
    }
}
