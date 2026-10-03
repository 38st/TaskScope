import Darwin
import Foundation

enum AutoStopRuleValidation {
    static let maximumRuntimeMinutes = 1_440

    struct Failure: Error, Equatable {
        var message: String
    }

    /// The form both stored rule paths and inventory paths are compared in:
    /// symlinks resolved through `realpath(3)` when the file exists, so a rule
    /// written as `/opt/homebrew/bin/node` matches the Cellar binary the kernel
    /// reports as the executable. A path that does not exist keeps Foundation's
    /// best-effort resolution.
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let standardizedLHS = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let standardizedRHS = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return standardizedLHS == standardizedRHS
            || canonicalPath(lhs) == canonicalPath(rhs)
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
