import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var authorized = false
    private var primed = false

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        authorized = granted
    }

    func prime(initialRunningNames: Set<String>) {
        lastRunningNames = initialRunningNames
        primed = true
    }

    func diffAndNotify(currentRunningNames: Set<String>) {
        guard primed, authorized else {
            lastRunningNames = currentRunningNames
            primed = true
            return
        }

        let started = currentRunningNames.subtracting(lastRunningNames)
        let stopped = lastRunningNames.subtracting(currentRunningNames)

        for name in started {
            notify(title: "Process Started", body: "\(name) is now running.")
        }
        for name in stopped {
            notify(title: "Process Stopped", body: "\(name) is no longer running.")
        }

        lastRunningNames = currentRunningNames
    }

    private var lastRunningNames: Set<String> = []

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
