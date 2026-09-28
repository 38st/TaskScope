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
                let state: GlobalProtectConnectionState
                switch string(item, kAXHelpAttribute) {
                case "Not Connected": state = .disconnected
                case "Connected": state = .connected
                case "Connecting...", "Disconnecting...": state = .busy
                default: state = .unavailable
                }
                continuation.resume(returning: state)
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
                var disconnectButton = button()
                if disconnectButton == nil {
                    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                        continuation.resume(returning: false)
                        return
                    }
                    // The popover is created asynchronously after AXPress.
                    for _ in 0..<20 {
                        Thread.sleep(forTimeInterval: 0.1)
                        disconnectButton = button()
                        if disconnectButton != nil { break }
                    }
                }
                guard let disconnectButton, application() != nil else {
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

    private func find(in roots: [AXUIElement], role: String, title: String? = nil) -> AXUIElement? {
        var pending = roots.map { ($0, 0) }
        var inspected = 0
        while let (element, depth) = pending.popLast(), inspected < 100 {
            inspected += 1
            if string(element, kAXRoleAttribute) == role,
               title == nil || string(element, kAXTitleAttribute) == title || string(element, kAXDescriptionAttribute) == title {
                return element
            }
            if depth < 8 {
                pending += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
            }
        }
        return nil
    }
}
