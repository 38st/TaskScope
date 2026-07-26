import AppKit
import Combine
import Foundation
import UserNotifications

struct ProcessNotificationBaseline {
    private(set) var runningNames: Set<String>?

    mutating func rebaseline(_ names: Set<String>) {
        runningNames = names
    }

    mutating func transitions(
        to names: Set<String>,
        canNotify: Bool
    ) -> (started: Set<String>, stopped: Set<String>) {
        guard canNotify, let previous = runningNames else {
            runningNames = names
            return ([], [])
        }
        runningNames = names
        return (names.subtracting(previous), previous.subtracting(names))
    }
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum AuthorizationState: Equatable, Sendable {
        case unknown
        case notDetermined
        case denied
        case authorized
        case provisional

        var label: String {
            switch self {
            case .unknown: "Unknown"
            case .notDetermined: "Not requested"
            case .denied: "Denied"
            case .authorized: "Allowed"
            case .provisional: "Provisional"
            }
        }
    }

    static let shared = NotificationService()

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    private var baseline = ProcessNotificationBaseline()

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert])
        await refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationState = Self.authorizationState(for: settings.authorizationStatus)
    }

    static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .provisional
        @unknown default:
            .unknown
        }
    }

    func prime(initialRunningNames: Set<String>) {
        baseline.rebaseline(initialRunningNames)
    }

    func diffAndNotify(currentRunningNames: Set<String>) {
        let transitions = baseline.transitions(
            to: currentRunningNames,
            canNotify: canDeliver
        )

        for name in transitions.started {
            notify(title: "Process Started", body: "\(name) is now running.")
        }
        for name in transitions.stopped {
            notify(title: "Process Stopped", body: "\(name) is no longer running.")
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner]

    private var canDeliver: Bool {
        Self.canDeliver(for: authorizationState)
    }

    nonisolated static func canDeliver(for state: AuthorizationState) -> Bool {
        state == .authorized || state == .provisional
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
