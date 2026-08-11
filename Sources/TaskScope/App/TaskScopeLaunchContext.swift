struct TaskScopeLaunchSignal: Equatable, Sendable {
    var arguments: [String]
    var launchedAsLoginItem: Bool
    var receivedOpenURL: Bool
}

enum TaskScopeLaunchContext: Equatable {
    case pending
    case interactive
    case loginItem
    case automation
    case urlAutomation
    case startupVerification

    static func detect(_ signal: TaskScopeLaunchSignal) -> TaskScopeLaunchContext {
        if signal.arguments.contains("--verify-startup") {
            return .startupVerification
        }
        if signal.launchedAsLoginItem {
            return .loginItem
        }
        if signal.arguments.contains("--background")
            || signal.arguments.contains("--automation") {
            return .automation
        }
        if signal.receivedOpenURL {
            return .urlAutomation
        }
        return .interactive
    }

    static func resolve(
        current: TaskScopeLaunchContext,
        signal: TaskScopeLaunchSignal,
        finalizeInteractiveLaunch: Bool
    ) -> TaskScopeLaunchContext {
        let detected = detect(signal)
        if detected.suppressesAutomaticWindowPresentation {
            return detected
        }
        if current != .pending, current.suppressesAutomaticWindowPresentation {
            return current
        }
        return finalizeInteractiveLaunch ? .interactive : .pending
    }

    static func receivingURL(
        current: TaskScopeLaunchContext,
        phase: TaskScopeLaunchPhase
    ) -> TaskScopeLaunchContext {
        guard current != .startupVerification else { return current }
        return phase == .starting ? .urlAutomation : current
    }

    var suppressesAutomaticWindowPresentation: Bool {
        self != .interactive
    }

    var allowsExplicitCommands: Bool {
        self != .startupVerification
    }

    var performsRuntimeBootstrap: Bool {
        self != .startupVerification
    }
}

enum TaskScopeLaunchPhase: Equatable, Sendable {
    case starting
    case running
}

@MainActor
enum TaskScopeExternalStateRefresh {
    static func perform(
        refreshLoginItem: () -> Void,
        refreshNotificationAuthorization: () async -> Void
    ) async {
        refreshLoginItem()
        await refreshNotificationAuthorization()
    }
}
