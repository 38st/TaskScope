import Foundation

enum AutoStopRuleValidation {
    static let maximumRuntimeMinutes = 1_440

    struct Failure: Error, Equatable {
        var message: String
    }

    static func validate(_ rule: AutoStopRule) -> Result<AutoStopRule, Failure> {
        var normalized = rule
        normalized.processName = rule.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = rule.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPath, !trimmedPath.isEmpty, !trimmedPath.hasPrefix("/") {
            return .failure(Failure(message: "Executable path must be absolute."))
        }
        normalized.executablePath = trimmedPath.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard !normalized.processName.isEmpty else {
            return .failure(Failure(message: "Process name is required."))
        }
        guard (1...maximumRuntimeMinutes).contains(normalized.runtimeMinutes) else {
            return .failure(Failure(
                message: "Runtime must be between 1 and \(maximumRuntimeMinutes) minutes."
            ))
        }
        if normalized.action == .kill,
           normalized.isEnabled,
           normalized.executablePath == nil {
            return .failure(Failure(
                message: "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules."
            ))
        }
        return .success(normalized)
    }

    static func validateStored(
        _ candidates: [AutoStopRule]
    ) -> (rules: [AutoStopRule], rejectedCount: Int) {
        var accepted: [AutoStopRule] = []
        var seenNames: Set<String> = []
        var rejectedCount = 0

        for candidate in candidates {
            var safelyMigrated = candidate
            // Older destructive rules were name-only. Preserve them for review but
            // disable them until the user supplies an executable path.
            if safelyMigrated.action == .kill, safelyMigrated.executablePath == nil {
                safelyMigrated.isEnabled = false
            }
            guard case .success(let normalized) = validate(safelyMigrated),
                  seenNames.insert(normalized.processName.lowercased()).inserted else {
                rejectedCount += 1
                continue
            }
            accepted.append(normalized)
        }
        return (accepted, rejectedCount)
    }
}
