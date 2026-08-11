import Foundation

@MainActor
final class AutoStopRulesStore: ObservableObject {
    static let maximumRuntimeMinutes = AutoStopRuleValidation.maximumRuntimeMinutes

    @Published private(set) var rules: [AutoStopRule] {
        didSet {
            normalizeRules()
            cancelUnauthorizedActions()
            saveRules()
        }
    }
    @Published private(set) var pendingPrompts: [AutoStopPrompt] = []
    @Published private(set) var events: [AutoStopEvent]
    @Published private(set) var engineError: String?
    @Published private(set) var isEngineRunning = false
    @Published private(set) var validationError: String?
    @Published private(set) var rulesRecoveryMessage: String?
    @Published private(set) var eventsRecoveryMessage: String?

    var recoveryMessages: [String] {
        [rulesRecoveryMessage, eventsRecoveryMessage].compactMap { $0 }
    }

    var currentPrompt: AutoStopPrompt? {
        pendingPrompts.first
    }

    private let rulesPersistence: RecoveringCodableStorage<[AutoStopRule]>
    private let eventsPersistence: RecoveringCodableStorage<[AutoStopEvent]>
    private let now: () -> Date
    private let inventory: any ProcessInventoryProviding
    private let pollingController: ProcessPollingController
    private let eventLimit: Int
    private var handledOccurrences: Set<AutoStopOccurrence> = []
    private var reportedFailures: Set<AutoStopOccurrence> = []
    private var actionHandler: ((AutoStopRule, AppProcess) async -> ProcessActionResult)?
    private var inFlightActions: [AutoStopOccurrence: Task<ProcessActionResult, Never>] = [:]
    private var isNormalizing = false
    private var allowsRulesPersistence: Bool
    private var allowsEventsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.autoStopRules.v1",
        eventsKey: String = "TaskScope.autoStopEvents.v1",
        inventory: any ProcessInventoryProviding = SystemProcessInventory(),
        eventLimit: Int = 200,
        now: @escaping () -> Date = Date.init,
        pollingController: ProcessPollingController? = nil
    ) {
        let boundedEventLimit = max(1, eventLimit)
        let rulesPersistence = RecoveringCodableStorage<[AutoStopRule]>(
            userDefaults: userDefaults,
            key: key
        )
        let eventsPersistence = RecoveringCodableStorage<[AutoStopEvent]>(
            userDefaults: userDefaults,
            key: eventsKey
        )
        self.rulesPersistence = rulesPersistence
        self.eventsPersistence = eventsPersistence
        self.inventory = inventory
        self.pollingController = pollingController ?? ProcessPollingController()
        self.eventLimit = boundedEventLimit
        self.now = now
        let rulesLoad = rulesPersistence.load()
        let eventsLoad = eventsPersistence.load()
        let loadedRules = (
            value: rulesLoad.value,
            message: rulesLoad.backupKey.map { "Unreadable data was backed up as \($0)." }
        )
        let loadedEvents = (
            value: eventsLoad.value,
            message: eventsLoad.backupKey.map { "Unreadable data was backed up as \($0)." }
        )
        let validatedRules = AutoStopRuleValidation.validateStored(loadedRules.value ?? [])
        var rulesMessage = loadedRules.message
        var permitsRulesPersistence = loadedRules.message == nil
        if loadedRules.message == nil, validatedRules.rejectedCount > 0,
           let backupKey = rulesPersistence.preserveCurrentPayload(
               suffix: "rejectedMigrationBackup"
           ) {
            permitsRulesPersistence = false
            rulesMessage = "Rejected \(validatedRules.rejectedCount) invalid or duplicate stored auto-stop rule\(validatedRules.rejectedCount == 1 ? "" : "s"). The first rejected payload is preserved as \(backupKey); reset after review to commit only the recovered safe rules."
        }
        // A decode failure must never lead to the unreadable payload being replaced
        // by the empty array we fell back to, so persistence stays disabled for that
        // key until the user explicitly resets it.
        allowsRulesPersistence = permitsRulesPersistence
        allowsEventsPersistence = loadedEvents.message == nil
        rules = validatedRules.rules
        events = Array((loadedEvents.value ?? []).prefix(boundedEventLimit))
        rulesRecoveryMessage = rulesMessage
        eventsRecoveryMessage = loadedEvents.message

        if allowsEventsPersistence,
           let loadedEventCount = loadedEvents.value?.count,
           loadedEventCount > boundedEventLimit {
            saveEvents()
        }
    }

    deinit {
        inFlightActions.values.forEach { $0.cancel() }
    }

    var hasUnreadableData: Bool {
        !allowsRulesPersistence || !allowsEventsPersistence
    }

    var isRulesReadOnlyAfterRecovery: Bool {
        !allowsRulesPersistence
    }

    var isEventsReadOnlyAfterRecovery: Bool {
        !allowsEventsPersistence
    }

    /// Accepts only the rules that decoded and passed current validation, then
    /// resumes durable rule mutations.
    func resetRulesAfterCorruption() {
        guard !allowsRulesPersistence else { return }
        allowsRulesPersistence = true
        rulesRecoveryMessage = nil
        validationError = nil
        saveRules()
    }

    /// Discards an unreadable event payload and resumes durable event logging.
    func resetEventsAfterCorruption() {
        guard !allowsEventsPersistence else { return }
        allowsEventsPersistence = true
        eventsRecoveryMessage = nil
        validationError = nil
        saveEvents()
    }

    /// Compatibility entry point for callers that explicitly choose to reset both
    /// independently protected payloads.
    func resetAfterCorruption() {
        resetRulesAfterCorruption()
        resetEventsAfterCorruption()
    }

    @discardableResult
    func add(_ rule: AutoStopRule) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        let normalized = validated(rule)
        guard let normalized else { return false }
        guard !rules.contains(where: {
            $0.processName.caseInsensitiveCompare(normalized.processName) == .orderedSame
        }) else {
            validationError = "A rule for \(normalized.processName) already exists."
            return false
        }
        validationError = nil
        rules.append(normalized)
        return true
    }

    @discardableResult
    func update(_ rule: AutoStopRule) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        guard let index = rules.firstIndex(where: { $0.id == rule.id }),
              let normalized = validated(rule) else {
            return false
        }
        guard !rules.contains(where: {
            $0.id != rule.id &&
            $0.processName.caseInsensitiveCompare(normalized.processName) == .orderedSame
        }) else {
            validationError = "A rule for \(normalized.processName) already exists."
            return false
        }
        validationError = nil
        rules[index] = normalized
        handledOccurrences = handledOccurrences.filter { $0.ruleID != rule.id }
        reportedFailures = reportedFailures.filter { $0.ruleID != rule.id }
        // Editing or disabling a rule must retire its live prompts too, exactly as
        // `remove(_:)` does; otherwise a disabled rule's alert stays actionable.
        pendingPrompts.removeAll { $0.rule.id == rule.id }
        return true
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for rule: AutoStopRule) -> Bool {
        var updated = rule
        updated.isEnabled = enabled
        return update(updated)
    }

    @discardableResult
    func duplicate(_ rule: AutoStopRule) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        var copy = rule
        copy.id = UUID()
        copy.processName = uniqueName(basedOn: rule.processName)
        return add(copy)
    }

    @discardableResult
    func remove(at offsets: IndexSet) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        let removedIDs = Set(offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
        rules.remove(atOffsets: offsets)
        handledOccurrences = handledOccurrences.filter { !removedIDs.contains($0.ruleID) }
        reportedFailures = reportedFailures.filter { !removedIDs.contains($0.ruleID) }
        pendingPrompts.removeAll { removedIDs.contains($0.rule.id) }
        validationError = nil
        return true
    }

    @discardableResult
    func remove(_ rule: AutoStopRule) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        guard rules.contains(where: { $0.id == rule.id }) else { return false }
        rules.removeAll { $0.id == rule.id }
        handledOccurrences = handledOccurrences.filter { $0.ruleID != rule.id }
        reportedFailures = reportedFailures.filter { $0.ruleID != rule.id }
        pendingPrompts.removeAll { $0.rule.id == rule.id }
        validationError = nil
        return true
    }

    func start(
        cadence: TimeInterval = 10,
        actionHandler: @escaping (AutoStopRule, AppProcess) async -> ProcessActionResult
    ) {
        self.actionHandler = actionHandler
        guard !isEngineRunning else { return }
        isEngineRunning = true
        pollingController.restart(interval: cadence, performImmediately: true) { [weak self] in
            await self?.evaluateNow()
        }
    }

    func restart(
        cadence: TimeInterval,
        actionHandler: @escaping (AutoStopRule, AppProcess) async -> ProcessActionResult
    ) {
        stop()
        start(cadence: cadence, actionHandler: actionHandler)
    }

    func stop() {
        pollingController.stop()
        inFlightActions.values.forEach { $0.cancel() }
        inFlightActions.removeAll()
        isEngineRunning = false
    }

    func evaluateNow() async {
        switch await inventory.load(fetchExtendedStats: false) {
        case .failure(let error):
            engineError = error.localizedDescription
        case .success(let processes):
            engineError = nil
            await evaluate(processes)
        }
    }

    /// Synchronously removes `prompt` from the queue and hands it back, or returns
    /// nil if it is already gone.
    ///
    /// Alert buttons must claim before doing any async work. SwiftUI writes
    /// `isPresented = false` as soon as a button is tapped, and that write-back runs
    /// before any `Task { }` the button enqueued — so an action that re-resolved the
    /// target afterwards would act on whatever prompt had become the queue head.
    func claimPrompt(_ prompt: AutoStopPrompt) -> AutoStopPrompt? {
        guard let index = pendingPrompts.firstIndex(where: { $0.id == prompt.id }) else { return nil }
        return pendingPrompts.remove(at: index)
    }

    /// Completes a stop for a prompt already claimed via `claimPrompt`.
    func finishStop(_ prompt: AutoStopPrompt) async {
        let result = await actionHandler?(prompt.rule, prompt.process) ?? .rejected
        record(
            prompt,
            outcome: result.succeeded ? .stopped : .failed,
            detail: result.succeeded ? "Stopped after confirmation." : "Stop request did not complete."
        )
    }

    /// Dismisses one specific prompt. Idempotent: dismissing a prompt that a button
    /// already claimed is a no-op, so SwiftUI's automatic write-back cannot consume
    /// a second, never-displayed prompt.
    func dismissPrompt(_ prompt: AutoStopPrompt) {
        guard let claimed = claimPrompt(prompt) else { return }
        record(claimed, outcome: .dismissed, detail: "Dismissed; this process occurrence will not prompt again.")
    }

    func stopCurrentPrompt() async {
        guard let prompt = currentPrompt, let claimed = claimPrompt(prompt) else { return }
        await finishStop(claimed)
    }

    func dismissCurrentPrompt() {
        guard let prompt = currentPrompt else { return }
        dismissPrompt(prompt)
    }

    @discardableResult
    func clearEvents() -> Bool {
        guard !rejectEventsIfReadOnly() else { return false }
        events.removeAll()
        saveEvents()
        validationError = nil
        return true
    }

    /// Compatibility entry point for focused callers; app enforcement uses `evaluateNow`.
    func evaluate(
        runningProcesses: [AppProcess],
        onAction: @escaping (AutoStopRule, AppProcess) -> Void
    ) {
        let activeRules = rules.filter(\.isEnabled)
        for process in runningProcesses {
            guard let runtime = process.runtimeSeconds else { continue }
            for rule in activeRules where matches(rule, process: process) {
                let occurrence = AutoStopOccurrence(ruleID: rule.id, processIdentity: process.identity)
                guard runtime >= TimeInterval(rule.runtimeMinutes) * 60,
                      !handledOccurrences.contains(occurrence) else {
                    continue
                }
                handledOccurrences.insert(occurrence)
                onAction(rule, process)
            }
        }
        pruneEndedOccurrences(runningProcesses)
    }

    /// A rule captured before an `await` may have been deleted or disabled while the
    /// action was in flight; `rules` is the only authority once we resume.
    private func isStillActive(_ rule: AutoStopRule) -> Bool {
        rules.contains { $0.id == rule.id && $0.isEnabled }
    }

    private func evaluate(_ processes: [AppProcess]) async {
        let activeRules = rules.filter(\.isEnabled)
        for process in processes {
            guard let runtime = process.runtimeSeconds else { continue }
            for rule in activeRules where matches(rule, process: process) && isStillActive(rule) {
                let occurrence = AutoStopOccurrence(ruleID: rule.id, processIdentity: process.identity)
                guard runtime >= TimeInterval(rule.runtimeMinutes) * 60,
                      !handledOccurrences.contains(occurrence) else {
                    continue
                }

                handledOccurrences.insert(occurrence)
                let prompt = AutoStopPrompt(id: occurrence, rule: rule, process: process)
                switch rule.action {
                case .prompt:
                    pendingPrompts.append(prompt)
                case .kill:
                    let action = Task { [actionHandler] in
                        guard !Task.isCancelled else { return ProcessActionResult.rejected }
                        return await actionHandler?(rule, process) ?? .rejected
                    }
                    inFlightActions[occurrence] = action
                    let result = await action.value
                    inFlightActions[occurrence] = nil
                    // The handler suspends, so the rule may have been deleted or
                    // disabled while it ran. Drop the outcome rather than acting
                    // under a rule the user has already retired.
                    guard isStillActive(rule) else {
                        handledOccurrences.remove(occurrence)
                        continue
                    }
                    if result.succeeded {
                        reportedFailures.remove(occurrence)
                        record(prompt, outcome: .stopped, detail: "Stopped automatically.")
                    } else {
                        // Nothing was signalled — most often because the process
                        // list could not be read. Un-handle so the next tick
                        // retries instead of abandoning a still-running process,
                        // but log the failure only once per occurrence so a
                        // persistent fault cannot flood the event log.
                        handledOccurrences.remove(occurrence)
                        if reportedFailures.insert(occurrence).inserted {
                            record(prompt, outcome: .failed, detail: "Automatic stop did not complete.")
                        }
                    }
                case .silent:
                    if !record(prompt, outcome: .logged, detail: "Runtime threshold reached.") {
                        // A log-only occurrence has not completed until its event is
                        // durably recorded. Retry after the event recovery gate is reset.
                        handledOccurrences.remove(occurrence)
                    }
                }
            }
        }
        pruneEndedOccurrences(processes)
    }

    private func pruneEndedOccurrences(_ processes: [AppProcess]) {
        let runningIdentities = Set(processes.map(\.identity))
        let ended = handledOccurrences.filter { !runningIdentities.contains($0.processIdentity) }
        reportedFailures = reportedFailures.filter { runningIdentities.contains($0.processIdentity) }
        guard !ended.isEmpty else { return }
        handledOccurrences.subtract(ended)
        for prompt in pendingPrompts where ended.contains(prompt.id) {
            record(prompt, outcome: .processEnded, detail: "Process ended before the prompt was handled.")
        }
        pendingPrompts.removeAll { ended.contains($0.id) }
    }

    @discardableResult
    private func record(
        _ prompt: AutoStopPrompt,
        outcome: AutoStopEvent.Outcome,
        detail: String
    ) -> Bool {
        events.insert(
            AutoStopEvent(
                timestamp: now(),
                processName: prompt.process.name,
                pid: prompt.process.pid,
                ruleID: prompt.rule.id,
                outcome: outcome,
                detail: detail
            ),
            at: 0
        )
        if events.count > eventLimit {
            events.removeLast(events.count - eventLimit)
        }
        // Keep truthful in-memory history while preserving an unreadable primary
        // payload. The recovery banner makes its non-durable state visible, and an
        // explicit reset commits the recovered session history.
        saveEvents()
        return true
    }

    private func matches(_ rule: AutoStopRule, process: AppProcess) -> Bool {
        rule.processName.caseInsensitiveCompare(process.name) == .orderedSame
    }

    private func cancelUnauthorizedActions() {
        let authorizedRuleIDs = Set(
            rules.lazy
                .filter { $0.isEnabled && $0.action == .kill }
                .map(\.id)
        )
        for (occurrence, task) in inFlightActions
            where !authorizedRuleIDs.contains(occurrence.ruleID) {
            task.cancel()
        }
    }

    func authorizesAutomaticStop(ruleID: UUID) -> Bool {
        rules.contains { $0.id == ruleID && $0.isEnabled && $0.action == .kill }
    }

    private func rejectRulesIfReadOnly() -> Bool {
        guard !allowsRulesPersistence else { return false }
        validationError = "Auto-stop rule data is in recovery mode; reset the rules before making changes."
        return true
    }

    private func rejectEventsIfReadOnly() -> Bool {
        guard !allowsEventsPersistence else { return false }
        validationError = "Auto-stop event data is in recovery mode; reset the event log before clearing it."
        return true
    }

    private func validated(_ rule: AutoStopRule) -> AutoStopRule? {
        switch AutoStopRuleValidation.validate(rule) {
        case .success(let normalized):
            return normalized
        case .failure(let error):
            validationError = error.message
            return nil
        }
    }

    private func uniqueName(basedOn name: String) -> String {
        var suffix = 2
        var candidate = "\(name) Copy"
        while rules.contains(where: { $0.processName.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) Copy \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func normalizeRules() {
        guard !isNormalizing else { return }
        var seen: Set<String> = []
        let normalized = rules.compactMap { rule -> AutoStopRule? in
            guard let valid = validated(rule) else { return nil }
            let key = valid.processName.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return valid
        }
        guard normalized != rules else { return }
        isNormalizing = true
        rules = normalized
        isNormalizing = false
    }

    private func saveRules() {
        guard allowsRulesPersistence else { return }
        rulesPersistence.save(rules)
    }

    private func saveEvents() {
        guard allowsEventsPersistence else { return }
        eventsPersistence.save(events)
    }

}
