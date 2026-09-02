import Foundation

protocol ProcessTerminating: Sendable {
    func settleAfterProcessChange() async
    @discardableResult
    func terminateProcess(named name: String, forceIfStillRunning: Bool) async -> ProcessTerminationOutcome
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func isProcessNamedRunning(_ name: String) async -> Bool
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool
}

protocol UserLaunchAgentControlling: Sendable {
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    /// Unloads the preset's user launch agents except any whose loaded pid is in
    /// `preservingPIDs` (used by Quit Helpers to keep an agent that runs the
    /// main process loaded).
    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func disableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
}

extension UserLaunchAgentControlling {
    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        await unloadUserLaunchAgents(for: preset)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        .notNeeded
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        .notNeeded
    }
}

protocol SystemLaunchDaemonControlling: Sendable {
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
}

protocol AppBundleLaunching: Sendable {
    func appBundleExists(at path: String) -> Bool
    func openAppBundle(at path: String) async -> Bool
}

protocol ProcessLifecycleServicing:
    ProcessTerminating,
    UserLaunchAgentControlling,
    SystemLaunchDaemonControlling,
    AppBundleLaunching {}

extension ProcessTerminating {
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await terminateProcess(named: preset.mainProcessName, forceIfStillRunning: true)
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await terminateProcess(named: name, forceIfStillRunning: true)
    }

    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds)
    }
}

struct SystemProcessLifecycleService: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange()
    }

    func terminateProcess(named name: String, forceIfStillRunning: Bool) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            policy: forceIfStillRunning ? .gracefulThenForce : .graceful
        )
    }

    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        return await ProcessLifecycleController.terminateProcess(
            named: preset.mainProcessName,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.mainExecutableDirectory
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.bundleContentsDirectory
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset)
    }

    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(
            for: preset,
            preservingPIDs: preservingPIDs
        )
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.disableUserLaunchAgents(for: preset)
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.enableUserLaunchAgents(for: preset)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset)
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(name, timeoutSeconds: timeoutSeconds)
    }

    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(
            preset.mainProcessName,
            timeoutSeconds: timeoutSeconds,
            expectedExecutableDirectory: preset.mainExecutableDirectory
        )
    }

    func openAppBundle(at path: String) async -> Bool {
        await ProcessLifecycleController.openAppBundle(at: path)
    }
}
