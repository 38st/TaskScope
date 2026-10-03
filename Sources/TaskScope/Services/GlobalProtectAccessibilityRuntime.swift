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

        // Check permission before touching the vendor app, so a denied request
        // never leaves an interface running that was not running before.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        guard trusted else {
            return .failed("Allow TaskScope in System Settings → Privacy & Security → Accessibility, then choose Quit All again. This lets TaskScope disconnect the VPN for you. Its services were left running.")
        }
        // UI control is confined to the fixed vendor executable, never a name
        // supplied by a preset. A running service without a UI gets its UI opened.
        let application = await applicationPID(openIfNeeded: true)
        guard let pid = application?.pid, ProcessListReader.executablePath(for: pid) == executable else {
            return .failed("GlobalProtect's interface could not be opened to disconnect. Its services were left running.")
        }
        return await GlobalProtectDisconnectController.disconnect(
            using: GlobalProtectAccessibilityRuntime(pid: pid),
            startupUnavailableObservations: application?.launched == true ? 20 : 0
        )
    }

    @MainActor
    private static func applicationPID(openIfNeeded: Bool) async -> (pid: Int32, launched: Bool)? {
        func currentPID() -> Int32? {
            NSWorkspace.shared.runningApplications.first {
                $0.executableURL?.path == executable && !$0.isTerminated
            }?.processIdentifier
        }
        if let pid = currentPID() { return (pid, false) }
        guard openIfNeeded else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // `runningApplications` refreshes only as the main run loop turns, so use
        // the launched app's own PID rather than re-reading that list at once.
        let launched = try? await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/GlobalProtect.app"), configuration: configuration
        )
        guard let pid = launched.map(\.processIdentifier) ?? currentPID() else { return nil }
        return (pid, true)
    }
}

/// AX elements never leave this worker's serial queue; slow vendor responses
/// cannot block SwiftUI or reorder the lifecycle mutation gate.
private final class GlobalProtectAccessibilityRuntime: GlobalProtectDisconnectRuntime, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TaskScope.GlobalProtectDisconnect", qos: .userInitiated)
    private let pid: Int32
    /// Set when an Accessibility request times out. Queue-confined. A hung
    /// vendor UI then fails the current observation quickly instead of costing
    /// one messaging timeout per element in a tree walk.
    private var isUnresponsive = false
    private var deadline = GlobalProtectDisconnectDeadline(timeLimit: 0)

    init(pid: Int32) { self.pid = pid }

    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isUnresponsive = false
                self.deadline = deadline
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
                continuation.resume(returning: isUnresponsive ? .unavailable : observation.state)
            }
        }
    }

    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isUnresponsive = false
                self.deadline = deadline
                guard let app = application(), let item = statusItem() else {
                    continuation.resume(returning: false)
                    return
                }
                func button() -> AXUIElement? {
                    find(in: elements(app, kAXWindowsAttribute), role: kAXButtonRole, title: "Disconnect")
                }
                revealControls(app: app, item: item, role: kAXButtonRole, title: "Disconnect")
                guard let disconnectButton = button(), boolean(disconnectButton, kAXEnabledAttribute),
                      application() != nil, prepareRequest(disconnectButton) else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning:
                    AXUIElementPerformAction(disconnectButton, kAXPressAction as CFString) == .success
                )
            }
        }
    }

    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async {
        try? await Task.sleep(nanoseconds: UInt64(min(0.5, deadline.remainingTime) * 1_000_000_000))
    }

    private func revealControls(app: AXUIElement, item: AXUIElement, role: String, title: String) {
        // AXPress can succeed without leaving a usable popover when another
        // app owns focus. Activate the fixed vendor app before opening it.
        // Reacquire on every observation: a one-time reveal is invalidated by
        // TaskScope's window handoff or a user switching applications.
        guard application() != nil, prepareRequest(app) else { return }
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        guard prepareRequest(item), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return }
        for _ in 0..<20 {
            guard !isUnresponsive, deadline.remainingTime > 0 else { return }
            Thread.sleep(forTimeInterval: min(0.1, deadline.remainingTime))
            if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        }
    }

    private func application() -> AXUIElement? {
        guard !isUnresponsive, deadline.remainingTime > 0,
              ProcessListReader.executablePath(for: pid) == GlobalProtectAccessibilityDisconnect.executable else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard prepareRequest(app) else { return nil }
        return app
    }

    private func statusItem() -> AXUIElement? {
        guard let app = application() else { return nil }
        guard let value = copyAttribute(app, kAXExtrasMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let menuBar = unsafeBitCast(value, to: AXUIElement.self)
        return find(in: elements(menuBar, kAXChildrenAttribute), role: kAXMenuBarItemRole)
    }

    /// Every AX request shares the controller's deadline, including tree walks
    /// within one observation. Zero would restore the global messaging timeout.
    private func prepareRequest(_ element: AXUIElement) -> Bool {
        let remaining = deadline.remainingTime
        guard !isUnresponsive, remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(1, remaining)))
        return true
    }

    /// Reads one attribute, recording a timeout so callers stop walking a
    /// vendor UI that has stopped answering.
    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepareRequest(element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .cannotComplete { isUnresponsive = true }
        return error == .success ? value : nil
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool {
        copyAttribute(element, attribute) as? Bool == true
    }

    private func find(in roots: [AXUIElement], role: String, title: String? = nil) -> AXUIElement? {
        var pending = roots.map { ($0, 0) }
        var inspected = 0
        while !isUnresponsive, deadline.remainingTime > 0,
              let (element, depth) = pending.popLast(), inspected < 100 {
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
