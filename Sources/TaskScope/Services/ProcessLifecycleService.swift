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
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
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
            expectedExecutableDirectory: Self.executableDirectory(for: preset)
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: Self.bundleContentsDirectory(for: preset)
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset)
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset)
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
            expectedExecutableDirectory: Self.executableDirectory(for: preset)
        )
    }

    func openAppBundle(at path: String) async -> Bool {
        await ProcessLifecycleController.openAppBundle(at: path)
    }

    private static func executableDirectory(for preset: WatchedAppPreset) -> String {
        URL(fileURLWithPath: preset.appPath, isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .standardizedFileURL.path + "/"
    }

    private static func bundleContentsDirectory(for preset: WatchedAppPreset) -> String {
        URL(fileURLWithPath: preset.appPath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .standardizedFileURL.path + "/"
    }
}
