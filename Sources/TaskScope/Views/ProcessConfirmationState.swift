import Combine
import Foundation

enum TaskScopePresentationStyle {
    case menuBarCompact
    case expandedWindow
}

@MainActor
final class ProcessConfirmationState: ObservableObject {
    enum TerminationMode: Equatable {
        case normal
        case force

        var title: String {
            switch self {
            case .normal: "Stop Process?"
            case .force: "Force Stop Process?"
            }
        }
    }

    struct PendingTermination: Equatable {
        let process: AppProcess
        let mode: TerminationMode
    }

    struct PendingBatchTermination: Equatable {
        let targets: [ProcessIdentity]
        let mode: TerminationMode

        /// Describes exactly the captured targets, so the dialog cannot drift
        /// from what will be signalled if the live state changes meanwhile.
        var message: String {
            let names = targets.prefix(3).map { identity in
                let component = URL(fileURLWithPath: identity.command).lastPathComponent
                return component.isEmpty ? identity.command : component
            }
            let suffix = targets.count > names.count
                ? " and \(targets.count - names.count) more"
                : ""
            let action = mode == .force ? "Force stop" : "Stop"
            return "\(action) \(targets.count) selected processes: \(names.joined(separator: ", "))\(suffix)."
        }
    }

    enum PresetAction: String, Equatable {
        case quitApp = "Quit App"
        case quitHelpers = "Quit Helpers"
        case quitAll = "Quit All Killable"
        case keepOff = "Keep GlobalProtect Off"
    }

    struct PendingPresetAction: Equatable {
        var preset: WatchedAppPreset
        var action: PresetAction

        var title: String {
            action == .quitAll && preset.hasCanonicalGlobalProtectIdentity ? "Quit All" : action.rawValue
        }
    }

    @Published private(set) var pendingTermination: PendingTermination?
    @Published private(set) var pendingBatchTermination: PendingBatchTermination?
    @Published var pendingPresetAction: PendingPresetAction?

    func requestTermination(_ process: AppProcess, mode: TerminationMode = .normal) {
        pendingTermination = PendingTermination(process: process, mode: mode)
    }

    func clearTermination() {
        pendingTermination = nil
    }

    func requestBatch(_ targets: [ProcessIdentity], mode: TerminationMode = .normal) {
        pendingBatchTermination = targets.isEmpty
            ? nil
            : PendingBatchTermination(targets: targets, mode: mode)
    }

    func clearBatch() {
        pendingBatchTermination = nil
    }

    func requestPresetAction(_ action: PresetAction, preset: WatchedAppPreset) {
        pendingPresetAction = PendingPresetAction(preset: preset, action: action)
    }

    func clearPresetAction() {
        pendingPresetAction = nil
    }

    var batchMessage: String {
        pendingBatchTermination?.message ?? ""
    }
}
