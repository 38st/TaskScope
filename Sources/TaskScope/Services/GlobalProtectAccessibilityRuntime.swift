import AppKit
import ApplicationServices
import Darwin
import Foundation

enum GlobalProtectAccessibilityDisconnect {
    static let executable = "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"

    static func disconnectIfNeeded() async -> GlobalProtectDisconnectResult {
        guard case .success(let processes) = await ProcessListReader.currentProcessList(fetchExtendedStats: false) else {
            return .failed("The process list is unavailable. GlobalProtect's services were left running.")
        }
        let snapshot = WatchedSnapshotBuilder(excludedPID: getpid()).snapshot(for: .globalProtect, in: processes)
        guard snapshot.hasAny else { return .disconnected }

        // UI control is confined to the fixed vendor executable, never a name
        // supplied by a preset. A running service without a UI gets its UI opened.
        let pid = await applicationPID(openIfNeeded: true)
        guard let pid, ProcessListReader.executablePath(for: pid) == executable else {
            return .failed("GlobalProtect's interface could not be opened to disconnect. Its services were left running.")
        }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard trusted else {
            return .failed("Allow TaskScope in System Settings → Privacy & Security → Accessibility, then choose Quit All again. This lets TaskScope disconnect the VPN for you. Its services were left running.")
        }
        return await GlobalProtectDisconnectController.disconnect(
            using: GlobalProtectAccessibilityRuntime(pid: pid)
        )
    }

    @MainActor
    private static func applicationPID(openIfNeeded: Bool) async -> Int32? {
        func currentPID() -> Int32? {
            NSWorkspace.shared.runningApplications.first {
                $0.executableURL?.path == executable && !$0.isTerminated
            }?.processIdentifier
        }
        if let pid = currentPID() { return pid }
        guard openIfNeeded else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/GlobalProtect.app"), configuration: configuration
        )
        return currentPID()
    }
}

/// AX elements never leave this worker's serial queue; slow vendor responses
/// cannot block SwiftUI or reorder the lifecycle mutation gate.
private final class GlobalProtectAccessibilityRuntime: GlobalProtectDisconnectRuntime, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TaskScope.GlobalProtectDisconnect", qos: .userInitiated)
    private let pid: Int32

    init(pid: Int32) { self.pid = pid }

    func connectionState() async -> GlobalProtectConnectionState {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let item = statusItem() else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                var observation = GlobalProtectConnectionObservation(status: string(item, kAXHelpAttribute))
                if observation.status == "Error", let app = application() {
                    revealControls(app: app, item: item, role: kAXStaticTextRole, title: "Connection Failed")
                    // All controls must belong to the same vendor window.
                    for window in elements(app, kAXWindowsAttribute) {
                        let roots = [window]
                        guard find(in: roots, role: kAXStaticTextRole, title: "Connection Failed") != nil else { continue }
                        observation.showsConnectionFailed = true
                        observation.canConnect = find(in: roots, role: kAXButtonRole, title: "Connect")
                            .map { boolean($0, kAXEnabledAttribute) } == true
                        observation.hasDisconnect = find(in: roots, role: kAXButtonRole, title: "Disconnect") != nil
                        break
                    }
                    // Do not accept an idle view if the status changed while
                    // its controls were being read.
                    observation.status = string(item, kAXHelpAttribute)
                }
                continuation.resume(returning: observation.state)
            }
        }
    }

    func pressDisconnect() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let app = application(), let item = statusItem() else {
                    continuation.resume(returning: false)
                    return
                }
                func button() -> AXUIElement? {
                    find(in: elements(app, kAXWindowsAttribute), role: kAXButtonRole, title: "Disconnect")
                }
                revealControls(app: app, item: item, role: kAXButtonRole, title: "Disconnect")
                guard let disconnectButton = button(), boolean(disconnectButton, kAXEnabledAttribute),
                      application() != nil else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning:
                    AXUIElementPerformAction(disconnectButton, kAXPressAction as CFString) == .success
                )
            }
        }
    }

    func waitForNextObservation() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func revealControls(app: AXUIElement, item: AXUIElement, role: String, title: String) {
        // AXPress can succeed without leaving a usable popover when another
        // app owns focus. Activate the fixed vendor app before opening it.
        // Reacquire on every observation: a one-time reveal is invalidated by
        // TaskScope's window handoff or a user switching applications.
        guard application() != nil else { return }
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        }
    }

    private func application() -> AXUIElement? {
        guard ProcessListReader.executablePath(for: pid) == GlobalProtectAccessibilityDisconnect.executable else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return app
    }

    private func statusItem() -> AXUIElement? {
        guard let app = application() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeBitCast(value, to: AXUIElement.self)
        return find(in: elements(menuBar, kAXChildrenAttribute), role: kAXMenuBarItemRole)
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return value as? Bool == true
    }

    private func find(in roots: [AXUIElement], role: String, title: String? = nil) -> AXUIElement? {
        var pending = roots.map { ($0, 0) }
        var inspected = 0
        while let (element, depth) = pending.popLast(), inspected < 100 {
            inspected += 1
            if string(element, kAXRoleAttribute) == role,
               title == nil || string(element, kAXTitleAttribute) == title || string(element, kAXDescriptionAttribute) == title
                || (role == kAXStaticTextRole && string(element, kAXValueAttribute) == title) {
                return element
            }
            if depth < 8 {
                pending += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
            }
        }
        return nil
    }
}
