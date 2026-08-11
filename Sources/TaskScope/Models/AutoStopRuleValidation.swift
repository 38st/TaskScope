import Foundation

enum AutoStopRuleValidation {
    static let maximumRuntimeMinutes = 1_440

    struct Failure: Error, Equatable {
        var message: String
    }

    static func validate(_ rule: AutoStopRule) -> Result<AutoStopRule, Failure> {
        var normalized = rule
        normalized.processName = rule.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.processName.isEmpty else {
            return .failure(Failure(message: "Process name is required."))
        }
        guard (1...maximumRuntimeMinutes).contains(normalized.runtimeMinutes) else {
            return .failure(Failure(
                message: "Runtime must be between 1 and \(maximumRuntimeMinutes) minutes."
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
            guard case .success(let normalized) = validate(candidate),
                  seenNames.insert(normalized.processName.lowercased()).inserted else {
                rejectedCount += 1
                continue
            }
            accepted.append(normalized)
        }
        return (accepted, rejectedCount)
    }
}
