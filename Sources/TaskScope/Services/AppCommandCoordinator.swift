import AppKit
import Foundation

enum TaskScopeCommand: Equatable {
    case refresh
    case openPreset(String)
    case stopPreset(String)
    case quitApplication
}

struct TaskScopeCommandResult: Equatable {
    enum Status: Equatable {
        case completed
        case rejected
        case failed
    }

    var status: Status
    var message: String

    var succeeded: Bool {
        status == .completed
    }
}

@MainActor
final class AppCommandCoordinator {
    private let processManager: ProcessManager
    private let presets: () -> [WatchedAppPreset]
    private let terminateApplication: @MainActor () -> Void

    init(
        processManager: ProcessManager,
        presets: @escaping () -> [WatchedAppPreset],
        terminateApplication: @escaping @MainActor () -> Void = AppCommandCoordinator.terminateApp
    ) {
        self.processManager = processManager
        self.presets = presets
        self.terminateApplication = terminateApplication
    }

    private static func terminateApp() {
        NSApp.terminate(nil)
    }

    func perform(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        switch command {
        case .refresh:
            await processManager.refreshWatchedStatus(showMessage: true)
            if let error = processManager.processLoadError {
                return TaskScopeCommandResult(status: .failed, message: error)
            }
            return TaskScopeCommandResult(status: .completed, message: processManager.message)

        case .openPreset(let name):
            guard let preset = preset(named: name) else {
                return missingPresetResult(name)
            }
            return await processManager.openApp(preset)

        case .stopPreset(let name):
            guard let preset = preset(named: name) else {
                return missingPresetResult(name)
            }
            return await processManager.quitAllKillable(preset)

        case .quitApplication:
            terminateApplication()
            return TaskScopeCommandResult(status: .completed, message: "TaskScope is quitting.")
        }
    }

    private func preset(named name: String) -> WatchedAppPreset? {
        presets().first { $0.matchesLookupName(name) }
    }

    private func missingPresetResult(_ name: String) -> TaskScopeCommandResult {
        TaskScopeCommandResult(
            status: .rejected,
            message: "No watched-app preset matches “\(name)”."
        )
    }

}

@MainActor
final class AppCommandBus {
    static let shared = AppCommandBus()

    private struct PendingCommand {
        var command: TaskScopeCommand
        var continuation: CheckedContinuation<TaskScopeCommandResult, Never>
    }

    private var handler: ((TaskScopeCommand) async -> TaskScopeCommandResult)?
    private var pending: [PendingCommand] = []

    private init() {}

    func install(
        handler: @escaping (TaskScopeCommand) async -> TaskScopeCommandResult
    ) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        for item in queued {
            Task {
                item.continuation.resume(returning: await handler(item.command))
            }
        }
    }

    func submit(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        if let handler {
            return await handler(command)
        }

        return await withCheckedContinuation { continuation in
            pending.append(PendingCommand(command: command, continuation: continuation))
        }
    }
}
