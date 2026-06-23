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
            if let name = target {
                Task { await Self.stopProcess(named: name) }
            }
        case "open":
            if let name = target {
                Task { await Self.openPreset(named: name) }
            }
        case "refresh":
            NotificationCenter.default.post(name: .taskScopeRefreshRequested, object: nil)
        case "quit":
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }

    private static func stopProcess(named name: String) async {
        let result = await ShellCommandRunner.run("/usr/bin/pkill -x \(ShellCommandRunner.shellQuoted(name)) 2>/dev/null || true")
        _ = result
    }

    private static func openPreset(named name: String) async {
        let path = "/Applications/\(name).app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }
}

extension Notification.Name {
    static let taskScopeRefreshRequested = Notification.Name("TaskScopeRefreshRequested")
}
