import AppKit
import ApplicationServices
import Darwin
import Foundation

enum ActivityMonitorSelectionAttempt: Equatable {
    case selected
    case notReady
    case accessibilityDenied(String)
    case failed(String)
}

enum ActivityMonitorHandoffOutcome: Equatable {
    case success
    case missingProcess
    case appLaunchFailed(String)
    case accessibilityDenied(String)
    case timedOut(lastError: String?)

    func message(for pid: Int32) -> String {
        switch self {
        case .success:
            "Selected PID \(pid) in Activity Monitor."
        case .missingProcess:
            "PID \(pid) is no longer running, so Activity Monitor could not select it."
        case .appLaunchFailed(let detail):
            "Could not open Activity Monitor: \(detail)"
        case .accessibilityDenied(let detail):
            "Activity Monitor opened, but Accessibility access was denied. Allow TaskScope in System Settings > Privacy & Security > Accessibility, then try again. \(detail)"
        case .timedOut(let lastError):
            if let lastError, !lastError.isEmpty {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out: \(lastError)"
            } else {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out."
            }
        }
    }
}

@MainActor
protocol ActivityMonitorOpening {
    func open() async throws
}

@MainActor
protocol ActivityMonitorProcessChecking {
    func processExists(pid: Int32) -> Bool
}

@MainActor
protocol ActivityMonitorProcessSelecting {
    func select(pid: Int32) -> ActivityMonitorSelectionAttempt
}

@MainActor
protocol ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome
}

@MainActor
final class ActivityMonitorCoordinator: ActivityMonitorCoordinating {
    private let opener: any ActivityMonitorOpening
    private let processChecker: any ActivityMonitorProcessChecking
    private let selector: any ActivityMonitorProcessSelecting
    private let maximumSelectionAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let sleep: @MainActor (UInt64) async -> Void

    convenience init() {
        self.init(
            opener: SystemActivityMonitorOpener(),
            processChecker: SystemActivityMonitorProcessChecker(),
            selector: SystemActivityMonitorProcessSelector()
        )
    }

    init(
        opener: any ActivityMonitorOpening,
        processChecker: any ActivityMonitorProcessChecking,
        selector: any ActivityMonitorProcessSelecting,
        maximumSelectionAttempts: Int = 8,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        sleep: @escaping @MainActor (UInt64) async -> Void = { duration in
            try? await Task.sleep(nanoseconds: duration)
        }
    ) {
        self.opener = opener
        self.processChecker = processChecker
        self.selector = selector
        self.maximumSelectionAttempts = max(1, maximumSelectionAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.sleep = sleep
    }

    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome {
        guard processChecker.processExists(pid: pid) else {
            return .missingProcess
        }

        do {
            try await opener.open()
        } catch {
            return .appLaunchFailed(error.localizedDescription)
        }

        var lastError: String?
        for attempt in 0..<maximumSelectionAttempts {
            guard processChecker.processExists(pid: pid) else {
                return .missingProcess
            }

            switch selector.select(pid: pid) {
            case .selected:
                return .success
            case .accessibilityDenied(let detail):
                return .accessibilityDenied(detail)
            case .failed(let detail):
                lastError = detail
            case .notReady:
                break
            }

            if attempt < maximumSelectionAttempts - 1 {
                await sleep(retryDelayNanoseconds)
            }
        }

        return .timedOut(lastError: lastError)
    }
}

struct SystemActivityMonitorOpener: ActivityMonitorOpening {
    private static let applicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"
    )

    func open() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: Self.applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: ActivityMonitorOpenError.noApplicationReturned)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum ActivityMonitorOpenError: LocalizedError {
    case noApplicationReturned

    var errorDescription: String? {
        "macOS did not return a running Activity Monitor application."
    }
}

struct SystemActivityMonitorProcessChecker: ActivityMonitorProcessChecking {
    func processExists(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}

@MainActor
protocol ActivityMonitorAccessibilityRuntime {
    func isProcessTrusted(prompt: Bool) -> Bool
    func activityMonitorProcessIdentifier() -> pid_t?
    func selectProcessRow(applicationPID: pid_t, targetPID: Int32) -> ActivityMonitorSelectionAttempt
}

@MainActor
struct SystemActivityMonitorProcessSelector: ActivityMonitorProcessSelecting {
    private let runtime: any ActivityMonitorAccessibilityRuntime

    init() {
        runtime = SystemActivityMonitorAccessibilityRuntime()
    }

    init(runtime: any ActivityMonitorAccessibilityRuntime) {
        self.runtime = runtime
    }

    func select(pid: Int32) -> ActivityMonitorSelectionAttempt {
        guard runtime.isProcessTrusted(prompt: true) else {
            return .accessibilityDenied(
                "macOS has not granted TaskScope permission to select another app's interface."
            )
        }

        guard let applicationPID = runtime.activityMonitorProcessIdentifier() else {
            return .notReady
        }

        return runtime.selectProcessRow(applicationPID: applicationPID, targetPID: pid)
    }
}

@MainActor
struct SystemActivityMonitorAccessibilityRuntime: ActivityMonitorAccessibilityRuntime {
    private static let activityMonitorBundleIdentifier = "com.apple.ActivityMonitor"
    private static let maximumTreeDepth = 12

    func isProcessTrusted(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }

        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func activityMonitorProcessIdentifier() -> pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.activityMonitorBundleIdentifier
        ).first?.processIdentifier
    }

    func selectProcessRow(
        applicationPID: pid_t,
        targetPID: Int32
    ) -> ActivityMonitorSelectionAttempt {
        let application = AXUIElementCreateApplication(applicationPID)

        if let rowSelection = selectVisibleRow(in: application, targetPID: targetPID) {
            return rowSelection
        }

        // A user's existing search or process-scope choice can hide an otherwise
        // valid PID. Normalize only the state needed for a visible handoff, then
        // let the coordinator retry after Activity Monitor refreshes its table.
        prepareProcessTable(in: application, targetPID: targetPID)
        return .notReady
    }

    private func selectVisibleRow(
        in application: AXUIElement,
        targetPID: Int32
    ) -> ActivityMonitorSelectionAttempt? {
        guard let windows = elements(application, attribute: kAXWindowsAttribute) else {
            return nil
        }

        for window in windows {
            guard let outline = firstDescendant(
                of: window,
                role: kAXOutlineRole,
                remainingDepth: Self.maximumTreeDepth
            ),
            let columns = elements(outline, attribute: kAXColumnsAttribute),
            let pidColumnIndex = ActivityMonitorPIDCellMatcher.pidColumnIndex(
                in: columns.map { string($0, attribute: kAXIdentifierAttribute) }
            ),
            let rows = elements(outline, attribute: kAXRowsAttribute) else {
                continue
            }

            for row in rows {
                guard let cells = elements(row, attribute: kAXChildrenAttribute),
                      let pidCellIndex = ActivityMonitorPIDCellMatcher.cellIndex(
                          columnRanges: cells.map {
                              indexRange(
                                  $0,
                                  attribute: kAXColumnIndexRangeAttribute
                              )
                          },
                          containing: pidColumnIndex
                      ) else {
                    continue
                }

                let pidCell = cells[pidCellIndex]
                let pidValueMatches = ActivityMonitorPIDCellMatcher.matches(
                    value: value(pidCell, attribute: kAXValueAttribute),
                    targetPID: targetPID
                )
                let childValueMatches = elements(
                    pidCell,
                    attribute: kAXChildrenAttribute
                )?.contains(where: {
                    ActivityMonitorPIDCellMatcher.matches(
                        value: value($0, attribute: kAXValueAttribute),
                        targetPID: targetPID
                    )
                }) ?? false
                guard pidValueMatches || childValueMatches else {
                    continue
                }

                let selectionError = AXUIElementSetAttributeValue(
                    outline,
                    kAXSelectedRowsAttribute as CFString,
                    [row] as CFArray
                )
                if selectionError != .success {
                    let rowSelectionError = AXUIElementSetAttributeValue(
                        row,
                        kAXSelectedAttribute as CFString,
                        kCFBooleanTrue
                    )
                    guard rowSelectionError == .success else {
                        return selectionAttempt(for: rowSelectionError)
                    }
                }

                return .selected
            }
        }

        return nil
    }

    private func prepareProcessTable(
        in application: AXUIElement,
        targetPID: Int32
    ) {
        _ = selectAllProcesses(in: application)
        _ = showPIDColumn(in: application)
        _ = filterProcessTable(in: application, targetPID: targetPID)
    }

    private func filterProcessTable(
        in application: AXUIElement,
        targetPID: Int32
    ) -> Bool {
        guard let processName = processName(for: targetPID) else {
            return false
        }
        guard let windows = elements(application, attribute: kAXWindowsAttribute) else {
            return false
        }

        for window in windows {
            guard let searchField = firstDescendant(
                of: window,
                subrole: kAXSearchFieldSubrole,
                remainingDepth: Self.maximumTreeDepth
            ),
            let currentValue = string(searchField, attribute: kAXValueAttribute),
            currentValue != processName else {
                continue
            }

            guard AXUIElementSetAttributeValue(
                searchField,
                kAXValueAttribute as CFString,
                processName as CFString
            ) == .success else {
                return false
            }
            _ = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
            return true
        }

        return false
    }

    private func processName(for pid: Int32) -> String? {
        if let localizedName = NSRunningApplication(
            processIdentifier: pid
        )?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
        !localizedName.isEmpty {
            return localizedName
        }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let byteCount = proc_name(pid, &buffer, UInt32(buffer.count))
        guard byteCount > 0 else {
            return nil
        }
        let bytes = buffer
            .prefix(Int(byteCount))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func selectAllProcesses(in application: AXUIElement) -> Bool {
        guard let viewMenuItems = activityMonitorViewMenuItems(in: application),
              viewMenuItems.indices.contains(4) else {
            return false
        }

        let allProcessesItem = viewMenuItems[4]
        if let mark = string(allProcessesItem, attribute: kAXMenuItemMarkCharAttribute),
           !mark.isEmpty {
            return false
        }

        return AXUIElementPerformAction(
            allProcessesItem,
            kAXPressAction as CFString
        ) == .success
    }

    private func showPIDColumn(in application: AXUIElement) -> Bool {
        guard let viewMenuItems = activityMonitorViewMenuItems(in: application),
              let columnsMenu = viewMenuItems.first,
              let submenu = elements(columnsMenu, attribute: kAXChildrenAttribute)?.first,
              let columnItems = elements(submenu, attribute: kAXChildrenAttribute),
              let processIDItem = columnItems.first else {
            return false
        }

        if let mark = string(processIDItem, attribute: kAXMenuItemMarkCharAttribute),
           !mark.isEmpty {
            return false
        }

        return AXUIElementPerformAction(
            processIDItem,
            kAXPressAction as CFString
        ) == .success
    }

    private func activityMonitorViewMenuItems(in application: AXUIElement) -> [AXUIElement]? {
        guard let menuBar = element(application, attribute: kAXMenuBarAttribute),
              let menuBarItems = elements(menuBar, attribute: kAXChildrenAttribute) else {
            return nil
        }

        // The View menu is identified structurally, without localized labels:
        // its first item is the Columns submenu, whose first child contains the
        // long list of selectable process columns.
        for menuBarItem in menuBarItems {
            guard let menu = elements(menuBarItem, attribute: kAXChildrenAttribute)?.first,
                  let items = elements(menu, attribute: kAXChildrenAttribute),
                  let firstItem = items.first,
                  let columnsSubmenu = elements(
                      firstItem,
                      attribute: kAXChildrenAttribute
                  )?.first,
                  let columnItems = elements(
                      columnsSubmenu,
                      attribute: kAXChildrenAttribute
                  ),
                  columnItems.count >= 20 else {
                continue
            }
            return items
        }

        return nil
    }

    private func firstDescendant(
        of element: AXUIElement,
        role: String,
        remainingDepth: Int
    ) -> AXUIElement? {
        if string(element, attribute: kAXRoleAttribute) == role {
            return element
        }
        guard remainingDepth > 0,
              let children = elements(element, attribute: kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            if let match = firstDescendant(
                of: child,
                role: role,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private func firstDescendant(
        of element: AXUIElement,
        subrole: String,
        remainingDepth: Int
    ) -> AXUIElement? {
        if string(element, attribute: kAXSubroleAttribute) == subrole {
            return element
        }
        guard remainingDepth > 0,
              let children = elements(element, attribute: kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            if let match = firstDescendant(
                of: child,
                subrole: subrole,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private func selectionAttempt(for error: AXError) -> ActivityMonitorSelectionAttempt {
        switch error {
        case .apiDisabled:
            return .accessibilityDenied("macOS rejected the Accessibility operation.")
        case .cannotComplete, .invalidUIElement:
            return .notReady
        default:
            return .failed("Activity Monitor Accessibility operation failed (\(error.rawValue)).")
        }
    }

    private func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let rawValue = value(element, attribute: attribute),
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        value(element, attribute: attribute) as? [AXUIElement]
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        value(element, attribute: attribute) as? String
    }

    private func indexRange(_ element: AXUIElement, attribute: String) -> CFRange? {
        guard let rawValue = value(element, attribute: attribute),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func value(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }
}

enum ActivityMonitorPIDCellMatcher {
    static func pidColumnIndex(in identifiers: [String?]) -> Int? {
        identifiers.firstIndex(where: { $0 == "PID" })
    }

    static func cellIndex(
        columnRanges: [CFRange?],
        containing columnIndex: Int
    ) -> Int? {
        guard columnIndex >= 0 else {
            return nil
        }
        let requestedIndex = CFIndex(columnIndex)

        return columnRanges.firstIndex(where: { optionalRange in
            guard let range = optionalRange,
                  range.location >= 0,
                  range.length > 0 else {
                return false
            }
            return requestedIndex >= range.location
                && requestedIndex - range.location < range.length
        })
    }

    static func matches(value: AnyObject?, targetPID: Int32) -> Bool {
        if let string = value as? String {
            return string == String(targetPID)
        }
        if let number = value as? NSNumber {
            return number.stringValue == String(targetPID)
        }
        return false
    }
}
