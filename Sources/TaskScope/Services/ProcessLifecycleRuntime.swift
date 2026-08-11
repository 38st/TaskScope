import Darwin
import Foundation

struct ProcessLifecycleRuntime: Sendable {
    var userID: uid_t
    var fileExists: @Sendable (String) -> Bool
    var launchAgentLabel: @Sendable (String) -> String? = { path in
        guard let data = FileManager.default.contents(atPath: path),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let label = dictionary["Label"] as? String else {
            return nil
        }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
    var runCommand: @Sendable (String, TimeInterval) async -> ShellCommandResult
    var loadProcessInventory: @Sendable () async -> Result<[AppProcess], ProcessInventoryError>
    var executablePathForPID: @Sendable (Int32) -> String? = {
        ProcessListReader.executablePath(for: $0)
    }
    var sendSignal: @Sendable (Int32, Int32) -> Bool = { signal, pid in
        Darwin.kill(pid, signal) == 0
    }
    var sleep: @Sendable (UInt64) async -> Void

    static let live = ProcessLifecycleRuntime(
        userID: getuid(),
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        runCommand: { command, timeout in
            await ShellCommandRunner.run(command, timeout: timeout)
        },
        loadProcessInventory: {
            await ProcessListReader.currentProcessList(fetchExtendedStats: false)
        },
        executablePathForPID: { ProcessListReader.executablePath(for: $0) },
        sendSignal: { signal, pid in Darwin.kill(pid, signal) == 0 },
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}
