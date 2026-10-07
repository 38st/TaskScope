import AppKit

struct MenuBarConfirmationRequest: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
}

/// Asks for confirmation outside the menu-bar window. A dialog attached to that
/// window stops accepting clicks once another app takes keyboard focus while
/// the window stays on screen, which GlobalProtect does whenever it launches.
@MainActor
protocol MenuBarConfirming: Sendable {
    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool
}

/// Brings TaskScope forward and asks in a standard app-modal alert, which takes
/// keyboard focus whatever state the menu-bar window is in.
@MainActor
struct AppModalMenuBarConfirmation: MenuBarConfirming {
    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.addButton(withTitle: request.confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
