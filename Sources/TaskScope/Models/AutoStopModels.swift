import Foundation

struct AutoStopRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var processName: String
    var executablePath: String?
    var runtimeMinutes: Int
    var action: Action
    var isEnabled: Bool = true
    private(set) var hasUnknownFields = false

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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, processName, executablePath, runtimeMinutes, action, isEnabled
    }

    init(
        id: UUID = UUID(),
        processName: String,
        executablePath: String? = nil,
        runtimeMinutes: Int,
        action: Action,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.processName = processName
        self.executablePath = executablePath
        self.runtimeMinutes = runtimeMinutes
        self.action = action
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        processName = try container.decode(String.self, forKey: .processName)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        runtimeMinutes = try container.decode(Int.self, forKey: .runtimeMinutes)
        action = try container.decode(Action.self, forKey: .action)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let allKeys = try decoder.container(keyedBy: AnyRuleCodingKey.self).allKeys
        hasUnknownFields = !Set(allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue)))
        if hasUnknownFields { isEnabled = false }
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

    enum Outcome: Codable, Hashable {
        case logged
        case stopped
        /// A stop signal was accepted; the exit is confirmed on a later tick.
        case stopRequested
        case failed
        case dismissed
        case processEnded
        /// A value written by another build. Preserved verbatim so the event
        /// survives a round trip and is never misreported as Logged.
        case unknown(String)

        var rawValue: String {
            switch self {
            case .logged: "logged"
            case .stopped: "stopped"
            case .stopRequested: "stopRequested"
            case .failed: "failed"
            case .dismissed: "dismissed"
            case .processEnded: "processEnded"
            case .unknown(let raw): raw
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "logged": self = .logged
            case "stopped": self = .stopped
            case "stopRequested": self = .stopRequested
            case "failed": self = .failed
            case "dismissed": self = .dismissed
            case "processEnded": self = .processEnded
            default: self = .unknown(rawValue)
            }
        }

        init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var label: String {
            switch self {
            case .logged: "Logged"
            case .stopped: "Stopped"
            case .stopRequested: "Stop requested"
            case .failed: "Failed"
            case .dismissed: "Dismissed"
            case .processEnded: "Ended"
            case .unknown(let raw): "Unknown (\(raw))"
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
        outcome = ((try? container.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? nil)
            ?? .unknown("missing")
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

private struct AnyRuleCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
