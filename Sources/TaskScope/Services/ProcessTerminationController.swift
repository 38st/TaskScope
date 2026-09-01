import Darwin
import Foundation

enum ProcessTerminationController {
    static func settle(runtime: ProcessLifecycleRuntime) async {
        await runtime.sleep(300_000_000)
    }

    static func terminate(
        named name: String,
        policy: TerminationPolicy,
        expectedExecutableDirectory: String?,
        excludingPID currentPID: Int32,
        runtime: ProcessLifecycleRuntime
    ) async -> ProcessTerminationOutcome {
        guard case .success(let initialInventory) = await runtime.loadProcessInventory() else {
            return .inventoryUnavailable
        }

        let targets = terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            in: initialInventory
        )
        let termTargets = targets.filter {
            executablePathStillMatches(
                $0,
                expectedExecutableDirectory: expectedExecutableDirectory,
                runtime: runtime
            )
        }
        guard !termTargets.isEmpty else { return .noMatchingProcesses }

        var signalWasRejected = false
        for process in termTargets where !runtime.sendSignal(SIGTERM, process.pid) {
            signalWasRejected = true
        }
        guard policy.allowsEscalation else {
            return signalWasRejected ? .signalRejected : .signalled
        }

        await settle(runtime: runtime)
        guard case .success(let refreshedInventory) = await runtime.loadProcessInventory() else {
            return signalWasRejected ? .signalRejected : .escalationUnavailable
        }

        let originalIdentities = Set(termTargets.map(\.identity))
        let remainingTargets = terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            in: refreshedInventory
        ).filter {
            originalIdentities.contains($0.identity)
                && executablePathStillMatches(
                    $0,
                    expectedExecutableDirectory: expectedExecutableDirectory,
                    runtime: runtime
                )
        }
        if signalWasRejected, remainingTargets.isEmpty {
            return .targetsExited
        }
        for process in remainingTargets where !runtime.sendSignal(SIGKILL, process.pid) {
            signalWasRejected = true
        }
        return signalWasRejected ? .signalRejected : .signalled
    }

    static func isRunning(
        named name: String,
        expectedExecutableDirectory: String?,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        guard case .success(let inventory) = await runtime.loadProcessInventory() else {
            return false
        }
        return !terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            in: inventory
        ).isEmpty
    }

    static func waitUntilRunning(
        named name: String,
        timeoutSeconds: TimeInterval,
        expectedExecutableDirectory: String?,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isRunning(
                named: name,
                expectedExecutableDirectory: expectedExecutableDirectory,
                runtime: runtime
            ) {
                return true
            }
            await runtime.sleep(300_000_000)
        }
        return await isRunning(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            runtime: runtime
        )
    }

    static func matchingProcesses(named name: String, in inventory: [AppProcess]) -> [AppProcess] {
        inventory.filter { $0.name == name }
    }

    static func terminationTargets(
        named name: String,
        expectedExecutableDirectory: String?,
        excludingPID: Int32,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        inventory.filter { process in
            guard process.pid != excludingPID else { return false }
            guard let expectedExecutableDirectory else {
                return process.name == name
            }
            guard let executablePath = process.executablePath,
                  executablePath.hasPrefix(expectedExecutableDirectory) else {
                return false
            }

            // `ps comm` is presentation-oriented and may be truncated or otherwise
            // differ from the executable name. For scoped lifecycle actions the
            // separately kernel-resolved vnode path is the stronger identity.
            return process.name == name
                || URL(fileURLWithPath: executablePath).lastPathComponent == name
        }
    }

    private static func executablePathStillMatches(
        _ process: AppProcess,
        expectedExecutableDirectory: String?,
        runtime: ProcessLifecycleRuntime
    ) -> Bool {
        guard let expectedExecutableDirectory else { return true }
        guard let inventoryPath = process.executablePath,
              let path = runtime.executablePathForPID(process.pid),
              path.hasPrefix("/") else {
            return false
        }
        // macOS has no pid handle. The refreshed start-time identity and repeated
        // vnode-path comparison narrow the residual exit/reuse race before kill(2).
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedInventoryPath = URL(fileURLWithPath: inventoryPath)
            .standardizedFileURL.path
        return standardizedPath == standardizedInventoryPath
            && standardizedPath.hasPrefix(expectedExecutableDirectory)
    }
}
