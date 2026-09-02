import AppKit
import Foundation

enum TaskScopeCommand: Equatable {
    case refresh
    case openPreset(String)
    case stopPreset(String)
    case openPresetEntity(WatchedPresetCommandTarget)
    case stopPresetEntity(WatchedPresetCommandTarget)
}

struct WatchedPresetCommandTarget: Equatable, Sendable {
    var id: UUID
    var displayName: String
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
    private let allowsCommands: () -> Bool

    init(
        processManager: ProcessManager,
        presets: @escaping () -> [WatchedAppPreset],
        allowsCommands: @escaping () -> Bool = { true }
    ) {
        self.processManager = processManager
        self.presets = presets
        self.allowsCommands = allowsCommands
    }

    func perform(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        guard allowsCommands() else {
            return TaskScopeCommandResult(
                status: .rejected,
                message: "Commands are disabled during startup verification."
            )
        }

        switch command {
        case .refresh:
            // Report this refresh's own outcome. `processLoadError` describes the
            // displayed process list, which a watched-status refresh does not
            // reload, so a stale list error must not fail a refresh that worked.
            let refreshed = await processManager.refreshWatchedStatus(showMessage: true)
            return TaskScopeCommandResult(
                status: refreshed ? .completed : .failed,
                message: processManager.message
            )

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

        case .openPresetEntity(let target):
            guard let preset = preset(id: target.id) else {
                return missingPresetResult(target.displayName)
            }
            return await processManager.openApp(preset)

        case .stopPresetEntity(let target):
            guard let preset = preset(id: target.id) else {
                return missingPresetResult(target.displayName)
            }
            return await processManager.quitAllKillable(preset)

        }
    }

    private func preset(named name: String) -> WatchedAppPreset? {
        presets().first { $0.matchesLookupName(name) }
    }

    private func preset(id: UUID) -> WatchedAppPreset? {
        presets().first { $0.id == id }
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
    private var drainTask: Task<Void, Never>?

    init() {}

    func install(
        handler: @escaping (TaskScopeCommand) async -> TaskScopeCommandResult
    ) {
        self.handler = handler
        startDrainingIfNeeded()
    }

    func submit(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        return await withCheckedContinuation { continuation in
            pending.append(PendingCommand(command: command, continuation: continuation))
            startDrainingIfNeeded()
        }
    }

    private func startDrainingIfNeeded() {
        guard handler != nil, drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drainPendingCommands()
        }
    }

    private func drainPendingCommands() async {
        while let handler, !pending.isEmpty {
            let item = pending.removeFirst()
            item.continuation.resume(returning: await handler(item.command))
        }
        drainTask = nil
        startDrainingIfNeeded()
    }
}
