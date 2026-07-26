import AppKit
import Foundation
import os

enum TaskScopeURLParser {
    enum ParseError: Error, Equatable, LocalizedError {
        case invalidScheme
        case missingTarget(String)
        case unsupportedAction(String)

        var errorDescription: String? {
            switch self {
            case .invalidScheme:
                "The URL must use the taskscope scheme."
            case .missingTarget(let action):
                "taskscope://\(action)/ requires a preset name."
            case .unsupportedAction(let action):
                "Unsupported TaskScope URL action: \(action.isEmpty ? "(empty)" : action)."
            }
        }
    }

    static func command(from url: URL) -> Result<TaskScopeCommand, ParseError> {
        guard url.scheme?.lowercased() == "taskscope" else {
            return .failure(.invalidScheme)
        }
        let action = url.host?.lowercased() ?? ""
        let target = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "refresh":
            return .success(.refresh)
        case "open", "stop":
            guard let target, !target.isEmpty else {
                return .failure(.missingTarget(action))
            }
            return .success(action == "open" ? .openPreset(target) : .stopPreset(target))
        case "quit":
            return .success(.quitApplication)
        default:
            return .failure(.unsupportedAction(action))
        }
    }
}

@MainActor
final class URLSchemeHandler {
    static let shared = URLSchemeHandler()
    private let logger = Logger(subsystem: "TaskScope", category: "URLScheme")
    private let submitCommand: @MainActor (TaskScopeCommand) async -> TaskScopeCommandResult
    private var willHandleCommand: (@MainActor (TaskScopeCommand) -> Void)?

    init(
        submitCommand: @escaping @MainActor (TaskScopeCommand) async -> TaskScopeCommandResult = {
            await AppCommandBus.shared.submit($0)
        },
        willHandleCommand: @escaping @MainActor (TaskScopeCommand) -> Void = { _ in }
    ) {
        self.submitCommand = submitCommand
        self.willHandleCommand = willHandleCommand
    }

    func register(
        willHandleCommand: @escaping @MainActor (TaskScopeCommand) -> Void = { _ in }
    ) {
        self.willHandleCommand = willHandleCommand
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value) else {
            logger.error("Rejected malformed TaskScope URL.")
            return
        }

        Task {
            await handle(url)
        }
    }

    @discardableResult
    func handle(_ url: URL) async -> TaskScopeCommandResult? {
        switch TaskScopeURLParser.command(from: url) {
        case .success(let command):
            willHandleCommand?(command)
            let result = await submitCommand(command)
            if !result.succeeded {
                logger.error("\(result.message, privacy: .public)")
            }
            return result
        case .failure(let error):
            logger.error("\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
