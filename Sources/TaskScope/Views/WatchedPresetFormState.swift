import Combine
import Foundation

@MainActor
final class WatchedPresetFormState: ObservableObject {
    @Published var displayName = ""
    @Published var mainProcess = ""
    @Published var helpers = ""
    @Published var protectedProcesses = ""
    @Published var appPath = "/Applications/"
    @Published var agentLabels = ""
    @Published var agentPlistPaths = ""
    @Published var editingPresetID: UUID?

    func prepareForNewPreset() {
        editingPresetID = nil
        displayName = ""
        mainProcess = ""
        helpers = ""
        protectedProcesses = ""
        appPath = "/Applications/"
        agentLabels = ""
        agentPlistPaths = ""
    }

    func prepareForEditing(_ preset: WatchedAppPreset) {
        editingPresetID = preset.id
        displayName = preset.displayName
        mainProcess = preset.mainProcessName
        helpers = preset.helperProcessNames.joined(separator: ", ")
        protectedProcesses = preset.protectedProcessNames.joined(separator: ", ")
        appPath = preset.appPath
        agentLabels = preset.userLaunchAgentJobs.map(\.label).joined(separator: ", ")
        agentPlistPaths = preset.userLaunchAgentJobs.map(\.plistPath).joined(separator: ", ")
    }

    func makePreset(existing: WatchedAppPreset?) -> Result<WatchedAppPreset, ValidationError> {
        let agents = PresetInputParser.parseUserLaunchAgentJobs(
            labels: agentLabels,
            paths: agentPlistPaths
        )
        guard agents.errors.isEmpty else {
            return .failure(ValidationError(message: agents.errors.joined(separator: " ")))
        }

        return .success(WatchedAppPreset(
            id: existing?.id ?? UUID(),
            displayName: displayName.isEmpty ? mainProcess : displayName,
            mainProcessName: mainProcess,
            helperProcessNames: PresetInputParser.list(from: helpers),
            protectedProcessNames: PresetInputParser.list(from: protectedProcesses),
            appPath: appPath,
            userLaunchAgentJobs: agents.value,
            systemLaunchDaemonJobs: existing?.systemLaunchDaemonJobs ?? [],
            notificationsEnabled: existing?.notificationsEnabled ?? true
        ))
    }

    struct ValidationError: Error, Equatable {
        var message: String
    }
}
