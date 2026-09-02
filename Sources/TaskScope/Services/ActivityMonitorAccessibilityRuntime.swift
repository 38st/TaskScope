import ApplicationServices
import AppKit
import Darwin
import Foundation

@MainActor
protocol ActivityMonitorAccessibilityRuntime {
    func isProcessTrusted(prompt: Bool) -> Bool
    func activityMonitorProcessIdentifier() -> pid_t?
    func selectProcessRow(applicationPID: pid_t, targetPID: Int32) async -> ActivityMonitorSelectionAttempt
    func restorePreparedState()
}

extension ActivityMonitorAccessibilityRuntime {
    func restorePreparedState() {}
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

    func restorePreparedState() {
        runtime.restorePreparedState()
    }

    func select(pid: Int32) async -> ActivityMonitorSelectionAttempt {
        guard runtime.isProcessTrusted(prompt: true) else {
            return .accessibilityDenied(
                "macOS has not granted TaskScope permission to select another app's interface."
            )
        }

        guard let applicationPID = runtime.activityMonitorProcessIdentifier() else {
            return .notReady
        }

        return await runtime.selectProcessRow(applicationPID: applicationPID, targetPID: pid)
    }
}

/// Activity Monitor table state a handoff changed. Held on the main actor
/// between attempts and handed to the worker for restoration. `AXUIElement` is
/// a CF type without a Sendable annotation; every element here is used only on
/// the worker's serial queue.
struct ActivityMonitorPreparedTableState: @unchecked Sendable {
    var searchField: AXUIElement?
    var searchValue = ""
    /// The search text TaskScope typed; restoration is skipped when the field
    /// no longer holds it, because the user has moved on.
    var searchValueSet = ""
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

@MainActor
final class SystemActivityMonitorAccessibilityRuntime: ActivityMonitorAccessibilityRuntime {
    private static let activityMonitorBundleIdentifier = "com.apple.ActivityMonitor"
    private static let restorationDelayNanoseconds: UInt64 = 4_000_000_000

    private let worker = ActivityMonitorAccessibilityWorker()
    private var preparedState: ActivityMonitorPreparedTableState?
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

    /// Every Accessibility call happens on the worker's queue; only the state
    /// bookkeeping returns to the main actor.
    func selectProcessRow(
        applicationPID: pid_t,
        targetPID: Int32
    ) async -> ActivityMonitorSelectionAttempt {
        let processName = Self.processName(for: targetPID)
        let outcome = await worker.selectOrPrepare(
            applicationPID: applicationPID,
            targetPID: targetPID,
            processName: processName,
            existingState: preparedState
        )
        preparedState = outcome.preparedState
        if outcome.preparedState != nil {
            scheduleProcessTableRestoration()
        }
        return outcome.attempt
    }

    /// Restores immediately (app termination) instead of after the delay.
    func restorePreparedState() {
        restorationTask?.cancel()
        restorationTask = nil
        guard let state = preparedState else { return }
        preparedState = nil
        worker.restoreNow(state)
    }

    private func scheduleProcessTableRestoration() {
        restorationTask?.cancel()
        restorationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.restorationDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let state = self.preparedState else { return }
            self.preparedState = nil
            self.restorationTask = nil
            await self.worker.restore(state)
        }
    }

    private static func processName(for pid: Int32) -> String? {
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
}

/// Identifies Activity Monitor menu items by title rather than by position, so a
/// menu that gained or lost an item cannot make TaskScope press the wrong one.
/// Failure to match means the corresponding table change is simply not made.
enum ActivityMonitorMenuMatcher {
    static let allProcessesTitles: Set<String> = ["all processes"]
    static let pidColumnTitles: Set<String> = ["pid", "process id"]

    static func allProcessesIndex(titles: [String?]) -> Int? {
        titles.firstIndex { allProcessesTitles.contains(normalized($0)) }
    }

    static func pidColumnIndex(titles: [String?]) -> Int? {
        titles.firstIndex { pidColumnTitles.contains(normalized($0)) }
    }

    /// The contiguous run of titled items around `index`, bounded by menu
    /// separators (items with no title). The process-scope radio group lives in
    /// exactly one such run.
    static func scopeGroupRange(titles: [String?], around index: Int) -> Range<Int> {
        guard titles.indices.contains(index) else { return index..<index }
        var lower = index
        while lower > 0, !isSeparator(titles[lower - 1]) {
            lower -= 1
        }
        var upper = index + 1
        while upper < titles.count, !isSeparator(titles[upper]) {
            upper += 1
        }
        return lower..<upper
    }

    private static func normalized(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isSeparator(_ title: String?) -> Bool {
        normalized(title).isEmpty
    }
}

/// Runs all Accessibility traffic on one serial queue. AX calls are synchronous
/// IPC into Activity Monitor; performed on the main actor for every row and
/// cell, up to eight attempts, they froze TaskScope's own UI.
final class ActivityMonitorAccessibilityWorker: @unchecked Sendable {
    struct Outcome: @unchecked Sendable {
        var attempt: ActivityMonitorSelectionAttempt
        var preparedState: ActivityMonitorPreparedTableState?
    }

    private static let maximumTreeDepth = 12
    private let queue = DispatchQueue(
        label: "TaskScope.ActivityMonitorAccessibility",
        qos: .userInitiated
    )

    func selectOrPrepare(
        applicationPID: pid_t,
        targetPID: Int32,
        processName: String?,
        existingState: ActivityMonitorPreparedTableState?
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.performSelectOrPrepare(
                        applicationPID: applicationPID,
                        targetPID: targetPID,
                        processName: processName,
                        existingState: existingState
                    )
                )
            }
        }
    }

    func restore(_ state: ActivityMonitorPreparedTableState) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.performRestore(state)
                continuation.resume()
            }
        }
    }

    /// Synchronous variant for application termination, where an async hop
    /// would never complete.
    func restoreNow(_ state: ActivityMonitorPreparedTableState) {
        queue.sync {
            performRestore(state)
        }
    }

    private func performSelectOrPrepare(
        applicationPID: pid_t,
        targetPID: Int32,
        processName: String?,
        existingState: ActivityMonitorPreparedTableState?
    ) -> Outcome {
        let application = AXUIElementCreateApplication(applicationPID)

        if let rowSelection = selectVisibleRow(in: application, targetPID: targetPID) {
            return Outcome(attempt: rowSelection, preparedState: existingState)
        }

        // A user's existing search or process-scope choice can hide an otherwise
        // valid PID. Normalize only the state needed for a visible handoff, then
        // let the coordinator retry after Activity Monitor refreshes its table.
        let state = prepareProcessTable(
            in: application,
            processName: processName,
            existingState: existingState
        )
        return Outcome(attempt: .notReady, preparedState: state.hasChanges ? state : nil)
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
            // Resolved once per outline, not once per row.
            let pidColumnIndex = ActivityMonitorPIDCellMatcher.pidColumnIndex(
                in: columns.map { string($0, attribute: kAXIdentifierAttribute) }
            ),
            let rows = elements(outline, attribute: kAXRowsAttribute) else {
                continue
            }

            for row in rows {
                guard let cells = elements(row, attribute: kAXChildrenAttribute),
                      let pidCell = pidCell(in: cells, pidColumnIndex: pidColumnIndex) else {
                    continue
                }

                let pidValueMatches = ActivityMonitorPIDCellMatcher.matches(
                    value: value(pidCell, attribute: kAXValueAttribute),
                    targetPID: targetPID
                )
                let childValueMatches = pidValueMatches ? false : (elements(
                    pidCell,
                    attribute: kAXChildrenAttribute
                )?.contains(where: {
                    ActivityMonitorPIDCellMatcher.matches(
                        value: value($0, attribute: kAXValueAttribute),
                        targetPID: targetPID
                    )
                }) ?? false)
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

    /// Reads only the PID cell of a row. The cell at the column's index is
    /// checked against its own column range first; only when the row omits
    /// empty cells does this fall back to scanning every cell's range.
    private func pidCell(in cells: [AXUIElement], pidColumnIndex: Int) -> AXUIElement? {
        if cells.indices.contains(pidColumnIndex),
           let range = indexRange(cells[pidColumnIndex], attribute: kAXColumnIndexRangeAttribute),
           ActivityMonitorPIDCellMatcher.cellIndex(columnRanges: [range], containing: pidColumnIndex) == 0 {
            return cells[pidColumnIndex]
        }
        guard let index = ActivityMonitorPIDCellMatcher.cellIndex(
            columnRanges: cells.map { indexRange($0, attribute: kAXColumnIndexRangeAttribute) },
            containing: pidColumnIndex
        ) else {
            return nil
        }
        return cells[index]
    }

    private func prepareProcessTable(
        in application: AXUIElement,
        processName: String?,
        existingState: ActivityMonitorPreparedTableState?
    ) -> ActivityMonitorPreparedTableState {
        var state = existingState ?? captureProcessTableState(in: application)

        // Each change is recorded only after the menu confirms it took effect,
        // so restoration never presses an item that was not actually toggled.
        if !state.processScopeChanged,
           let allProcessesItem = state.allProcessesItem,
           let previousProcessScopeItem = state.previousProcessScopeItem,
           AXUIElementPerformAction(
               allProcessesItem,
               kAXPressAction as CFString
           ) == .success,
           isMarked(allProcessesItem) {
            state.previousProcessScopeItem = previousProcessScopeItem
            state.processScopeChanged = true
        }

        if !state.processIDWasVisible,
           !state.processIDWasShown,
           let processIDItem = state.processIDItem,
           AXUIElementPerformAction(
               processIDItem,
               kAXPressAction as CFString
           ) == .success,
           isMarked(processIDItem) {
            state.processIDWasShown = true
        }

        if !state.searchWasChanged,
           let processName,
           let searchField = state.searchField,
           state.searchValue != processName,
           AXUIElementSetAttributeValue(
               searchField,
               kAXValueAttribute as CFString,
               processName as CFString
           ) == .success {
            _ = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
            state.searchValueSet = processName
            state.searchWasChanged = true
        }

        return state
    }

    private func captureProcessTableState(
        in application: AXUIElement
    ) -> ActivityMonitorPreparedTableState {
        var state = ActivityMonitorPreparedTableState()

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

        let viewTitles = viewMenuItems.map { string($0, attribute: kAXTitleAttribute) }
        if let allProcessesIndex = ActivityMonitorMenuMatcher.allProcessesIndex(titles: viewTitles) {
            let allProcessesItem = viewMenuItems[allProcessesIndex]
            state.allProcessesItem = allProcessesItem
            if !isMarked(allProcessesItem) {
                let group = ActivityMonitorMenuMatcher.scopeGroupRange(
                    titles: viewTitles,
                    around: allProcessesIndex
                )
                state.previousProcessScopeItem = viewMenuItems[group].first(where: isMarked)
            }
        }

        if let columnsMenu = viewMenuItems.first,
           let submenu = elements(columnsMenu, attribute: kAXChildrenAttribute)?.first,
           let columnItems = elements(submenu, attribute: kAXChildrenAttribute) {
            let columnTitles = columnItems.map { string($0, attribute: kAXTitleAttribute) }
            if let pidIndex = ActivityMonitorMenuMatcher.pidColumnIndex(titles: columnTitles) {
                state.processIDItem = columnItems[pidIndex]
                state.processIDWasVisible = isMarked(columnItems[pidIndex])
            }
        }

        return state
    }

    /// Each field is put back only when it still holds the value TaskScope set.
    /// If the user changed the search, the scope, or the column since the
    /// handoff, their choice wins and that field is left alone.
    private func performRestore(_ state: ActivityMonitorPreparedTableState) {
        if state.searchWasChanged,
           let searchField = state.searchField,
           string(searchField, attribute: kAXValueAttribute) ?? "" == state.searchValueSet {
            if AXUIElementSetAttributeValue(
                searchField,
                kAXValueAttribute as CFString,
                state.searchValue as CFString
            ) == .success {
                _ = AXUIElementPerformAction(searchField, kAXConfirmAction as CFString)
            }
        }
        if state.processScopeChanged,
           let allProcessesItem = state.allProcessesItem,
           isMarked(allProcessesItem),
           let item = state.previousProcessScopeItem {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        if state.processIDWasShown,
           let item = state.processIDItem,
           isMarked(item) {
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
        // long list of selectable process columns. Individual items inside it
        // are then matched by title.
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
