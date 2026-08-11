import Foundation

struct AutoStopRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var processName: String
    var runtimeMinutes: Int
    var action: Action
    var isEnabled: Bool = true

    enum Action: String, Codable, CaseIterable, Identifiable {
        case prompt
        case kill
        case silent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .prompt: "Prompt"
            case .kill: "Auto Stop"
            case .silent: "Log Only"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, processName, runtimeMinutes, action, isEnabled
    }

    init(
        id: UUID = UUID(),
        processName: String,
        runtimeMinutes: Int,
        action: Action,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.processName = processName
        self.runtimeMinutes = runtimeMinutes
        self.action = action
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        processName = try container.decode(String.self, forKey: .processName)
        runtimeMinutes = try container.decode(Int.self, forKey: .runtimeMinutes)
        action = try container.decode(Action.self, forKey: .action)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct AutoStopPrompt: Identifiable, Equatable {
    var id: AutoStopOccurrence
    var rule: AutoStopRule
    var process: AppProcess
}

struct AutoStopOccurrence: Hashable {
    var ruleID: UUID
    var processIdentity: ProcessIdentity
}

struct AutoStopEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var processName: String
    var pid: Int32
    var ruleID: UUID
    var outcome: Outcome
    var detail: String

    enum Outcome: String, Codable {
        case logged
        case stopped
        case failed
        case dismissed
        case processEnded

        var label: String {
            switch self {
            case .logged: "Logged"
            case .stopped: "Stopped"
            case .failed: "Failed"
            case .dismissed: "Dismissed"
            case .processEnded: "Ended"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, processName, pid, ruleID, outcome, detail
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        processName: String,
        pid: Int32,
        ruleID: UUID,
        outcome: Outcome,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.processName = processName
        self.pid = pid
        self.ruleID = ruleID
        self.outcome = outcome
        self.detail = detail
    }

    /// Hand-written so a payload written by another build still decodes: the
    /// synthesized decoder ignores property defaults and hard-fails on any key it
    /// does not find, which would make one added field destroy the whole log.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? ""
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        outcome = (try? container.decode(Outcome.self, forKey: .outcome)) ?? .logged
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}
