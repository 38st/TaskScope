import Foundation

@MainActor
final class SavedSelectionsStore: ObservableObject {
    struct SavedProcess: Codable, Equatable, Identifiable {
        var pid: Int32
        var command: String
        var executableName: String

        var id: String {
            "\(command)|\(executableName)|\(pid)"
        }

        init(pid: Int32, command: String, executableName: String) {
            self.pid = pid
            self.command = command
            self.executableName = executableName
        }

        init(process: AppProcess) {
            self.init(pid: process.pid, command: process.command, executableName: process.name)
        }

        private enum CodingKeys: String, CodingKey {
            case pid, command, executableName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = try container.decode(Int32.self, forKey: .pid)
            command = try container.decode(String.self, forKey: .command)
            executableName = try container.decodeIfPresent(String.self, forKey: .executableName)
                ?? URL(fileURLWithPath: command).lastPathComponent
        }
    }

    struct SavedSelection: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var pids: [Int32]
        var processes: [SavedProcess]
        var isLegacyUnsupported: Bool

        private enum CodingKeys: String, CodingKey {
            case id, name, pids, processes, isLegacyUnsupported
        }

        init(
            id: UUID = UUID(),
            name: String,
            pids: [Int32],
            processes: [SavedProcess],
            isLegacyUnsupported: Bool = false
        ) {
            self.id = id
            self.name = name
            self.pids = pids
            self.processes = processes
            self.isLegacyUnsupported = isLegacyUnsupported
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Recovered Selection"
            pids = try container.decodeIfPresent([Int32].self, forKey: .pids) ?? []
            if let decodedProcesses = try container.decodeIfPresent(
                [SavedProcess].self,
                forKey: .processes
            ) {
                processes = decodedProcesses
                isLegacyUnsupported = try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isLegacyUnsupported
                ) ?? false
            } else {
                processes = []
                isLegacyUnsupported = !pids.isEmpty
            }
        }
    }

    struct RecallResult: Equatable {
        var matched: [AppProcess]
        var unmatched: [SavedProcess]
        var ambiguous: [SavedProcess]
        var legacyUnsupported: Bool

        var summary: String {
            if legacyUnsupported {
                return "This legacy selection contains only PIDs and cannot be recalled safely."
            }
            return "\(matched.count) matched, \(unmatched.count) unavailable, \(ambiguous.count) ambiguous."
        }
    }

    @Published var selections: [SavedSelection] {
        didSet { saveToDefaults() }
    }
    @Published private(set) var validationError: String?
    @Published private(set) var recoveryMessage: String?

    private let userDefaults: UserDefaults
    private let key: String
    private var allowsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.savedSelections.v1"
    ) {
        self.userDefaults = userDefaults
        self.key = key
        allowsPersistence = true
        if let data = userDefaults.data(forKey: key) {
            do {
                selections = try JSONDecoder().decode([SavedSelection].self, from: data)
            } catch {
                let backupKey = "\(key).corruptBackup"
                // Preserve the first backup rather than clobbering it on a later
                // corrupt read.
                if userDefaults.data(forKey: backupKey) == nil {
                    userDefaults.set(data, forKey: backupKey)
                }
                selections = []
                // Writing now would replace the unreadable payload with the empty
                // array we fell back to, destroying it at its primary key.
                allowsPersistence = false
                recoveryMessage = "Saved selections were unreadable and backed up as \(backupKey)."
            }
        } else {
            selections = []
        }
    }

    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// Discards the unreadable payload and resumes writing, keeping whatever the
    /// user rebuilt during the corrupt session.
    func resetAfterCorruption() {
        allowsPersistence = true
        recoveryMessage = nil
        saveToDefaults()
    }

    @discardableResult
    func save(name: String, processes: [AppProcess]) -> Bool {
        guard allowsPersistence else {
            validationError = "Saved selection data is unreadable; reset it before saving."
            return false
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "Selection name is required."
            return false
        }
        guard !processes.isEmpty else {
            validationError = "Select at least one process."
            return false
        }
        guard !containsName(trimmedName) else {
            validationError = "A saved selection named \(trimmedName) already exists."
            return false
        }

        validationError = nil
        selections.append(
            SavedSelection(
                name: trimmedName,
                pids: processes.map(\.pid),
                processes: processes.map(SavedProcess.init)
            )
        )
        return true
    }

    @discardableResult
    func rename(_ selection: SavedSelection, to name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "Selection name is required."
            return false
        }
        guard !containsName(trimmedName, excluding: selection.id) else {
            validationError = "A saved selection named \(trimmedName) already exists."
            return false
        }
        guard let index = selections.firstIndex(where: { $0.id == selection.id }) else {
            return false
        }
        validationError = nil
        selections[index].name = trimmedName
        return true
    }

    func resolve(_ selection: SavedSelection, in processes: [AppProcess]) -> RecallResult {
        guard !selection.isLegacyUnsupported else {
            return RecallResult(
                matched: [],
                unmatched: [],
                ambiguous: [],
                legacyUnsupported: true
            )
        }

        var matched: [AppProcess] = []
        var unmatched: [SavedProcess] = []
        var ambiguous: [SavedProcess] = []
        var claimedIdentities: Set<ProcessIdentity> = []

        for saved in selection.processes {
            let exactCommand = processes.filter { $0.command == saved.command }
            let candidates = exactCommand.isEmpty
                ? processes.filter {
                    $0.name.caseInsensitiveCompare(saved.executableName) == .orderedSame
                }
                : exactCommand

            let unclaimed = candidates.filter { !claimedIdentities.contains($0.identity) }
            if unclaimed.count == 1, let match = unclaimed.first {
                matched.append(match)
                claimedIdentities.insert(match.identity)
            } else if candidates.isEmpty {
                unmatched.append(saved)
            } else {
                ambiguous.append(saved)
            }
        }

        return RecallResult(
            matched: matched,
            unmatched: unmatched,
            ambiguous: ambiguous,
            legacyUnsupported: false
        )
    }

    func remove(at offsets: IndexSet) {
        selections.remove(atOffsets: offsets)
    }

    func remove(_ selection: SavedSelection) {
        selections.removeAll { $0.id == selection.id }
    }

    private func containsName(_ name: String, excluding id: UUID? = nil) -> Bool {
        selections.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func saveToDefaults() {
        guard allowsPersistence, let data = try? JSONEncoder().encode(selections) else { return }
        userDefaults.set(data, forKey: key)
    }

}
