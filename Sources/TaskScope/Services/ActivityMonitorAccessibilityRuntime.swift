import ApplicationServices
import AppKit
import Darwin
import Foundation

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
final class SystemActivityMonitorAccessibilityRuntime: ActivityMonitorAccessibilityRuntime {
    private static let activityMonitorBundleIdentifier = "com.apple.ActivityMonitor"
    private static let maximumTreeDepth = 12
    private static let restorationDelayNanoseconds: UInt64 = 4_000_000_000

    private struct PreparedProcessTableState {
        var searchField: AXUIElement?
        var searchValue = ""
        var allProcessesItem: AXUIElement?
        var previousProcessScopeItem: AXUIElement?
        var processScopeChanged = false
        var processIDItem: AXUIElement?
        var processIDWasVisible = true
        var processIDWasShown = false
        var searchWasChanged = false

        var hasChanges: Bool {
            processScopeChanged || processIDWasShown || searchWasChanged
        }
    }

    private var preparedState: PreparedProcessTableState?
    private var restorationTask: Task<Void, Never>?

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
        var state = preparedState ?? captureProcessTableState(in: application)

        if !state.processScopeChanged,
           let allProcessesItem = state.allProcessesItem,
           let previousProcessScopeItem = state.previousProcessScopeItem,
           AXUIElementPerformAction(
               allProcessesItem,
               kAXPressAction as CFString
           ) == .success {
            state.previousProcessScopeItem = previousProcessScopeItem
            state.processScopeChanged = true
        }

        if !state.processIDWasVisible,
           !state.processIDWasShown,
           let processIDItem = state.processIDItem,
           AXUIElementPerformAction(
               processIDItem,
               kAXPressAction as CFString
           ) == .success {
            state.processIDWasShown = true
        }

        if !state.searchWasChanged,
           let processName = processName(for: targetPID),
           let searchField = state.searchField,
           state.searchValue != processName,
           AXUIElementSetAttributeValue(
               searchField,
               kAXValueAttribute as CFString,
               processName as CFString
           ) == .success {
            _ = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
            state.searchWasChanged = true
        }

        preparedState = state.hasChanges ? state : nil
        if state.hasChanges {
            scheduleProcessTableRestoration()
        }
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

    private func captureProcessTableState(
        in application: AXUIElement
    ) -> PreparedProcessTableState {
        var state = PreparedProcessTableState()

        if let window = elements(application, attribute: kAXWindowsAttribute)?.first,
           let searchField = firstDescendant(
               of: window,
               subrole: kAXSearchFieldSubrole,
               remainingDepth: Self.maximumTreeDepth
           ) {
            state.searchField = searchField
            state.searchValue = string(searchField, attribute: kAXValueAttribute) ?? ""
        }

        guard let viewMenuItems = activityMonitorViewMenuItems(in: application) else {
            return state
        }

        if viewMenuItems.indices.contains(4) {
            let allProcessesItem = viewMenuItems[4]
            state.allProcessesItem = allProcessesItem
            let allProcessesIsSelected = isMarked(allProcessesItem)
            if !allProcessesIsSelected {
                let upperBound = min(viewMenuItems.count, 13)
                state.previousProcessScopeItem = viewMenuItems[4..<upperBound]
                    .first(where: isMarked)
            }
        }

        if let columnsMenu = viewMenuItems.first,
           let submenu = elements(columnsMenu, attribute: kAXChildrenAttribute)?.first,
           let processIDItem = elements(
               submenu,
               attribute: kAXChildrenAttribute
           )?.first {
            state.processIDItem = processIDItem
            state.processIDWasVisible = isMarked(processIDItem)
        }

        return state
    }

    private func scheduleProcessTableRestoration() {
        restorationTask?.cancel()
        restorationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.restorationDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.restorePreparedProcessTableState()
        }
    }

    private func restorePreparedProcessTableState() {
        guard let state = preparedState else { return }
        preparedState = nil
        restorationTask = nil

        if state.searchWasChanged, let searchField = state.searchField {
            if AXUIElementSetAttributeValue(
                searchField,
                kAXValueAttribute as CFString,
                state.searchValue as CFString
            ) == .success {
                _ = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
            }
        }
        if state.processScopeChanged, let item = state.previousProcessScopeItem {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        if state.processIDWasShown, let item = state.processIDItem {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    private func isMarked(_ element: AXUIElement) -> Bool {
        guard let mark = string(element, attribute: kAXMenuItemMarkCharAttribute) else {
            return false
        }
        return !mark.isEmpty
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
