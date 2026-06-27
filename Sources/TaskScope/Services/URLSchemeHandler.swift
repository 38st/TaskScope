import AppKit
import Foundation

@MainActor
final class URLSchemeHandler {
    static let shared = URLSchemeHandler()

    private init() {}

    func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlStr = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlStr),
              url.scheme?.lowercased() == "taskscope" else { return }

        let action = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let target = pathComponents.first?.removingPercentEncoding

        switch action {
        case "stop":
            break
        case "open":
            if let name = target {
                Task { await Self.openPreset(named: name) }
            }
        case "refresh":
            NotificationCenter.default.post(name: .taskScopeRefreshRequested, object: nil)
        case "quit":
            break
        default:
            break
        }
    }

    private static func openPreset(named name: String) async {
        guard let preset = WatchedAppsDefaults.persistedPresets().first(where: { $0.matchesLookupName(name) }),
              FileManager.default.fileExists(atPath: preset.appPath) else {
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: preset.appPath))
    }
}

extension Notification.Name {
    static let taskScopeRefreshRequested = Notification.Name("TaskScopeRefreshRequested")
}
