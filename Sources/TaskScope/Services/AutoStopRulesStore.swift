import Foundation

struct AutoStopRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var processName: String
    var runtimeMinutes: Int
    var action: Action
    var isEnabled: Bool = true

    enum Action: String, Codable, CaseIterable, Identifiable {
        case prompt
        case kill
        case silent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .prompt: "Prompt"
            case .kill: "Auto Stop"
            case .silent: "Log Only"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, processName, runtimeMinutes, action, isEnabled
    }

    init(
        id: UUID = UUID(),
        processName: String,
        runtimeMinutes: Int,
        action: Action,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.processName = processName
        self.runtimeMinutes = runtimeMinutes
        self.action = action
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        processName = try container.decode(String.self, forKey: .processName)
        runtimeMinutes = try container.decode(Int.self, forKey: .runtimeMinutes)
        action = try container.decode(Action.self, forKey: .action)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct AutoStopPrompt: Identifiable, Equatable {
    var id: AutoStopOccurrence
    var rule: AutoStopRule
    var process: AppProcess
}

struct AutoStopOccurrence: Hashable {
    var ruleID: UUID
    var processIdentity: ProcessIdentity
}

struct AutoStopEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var processName: String
    var pid: Int32
    var ruleID: UUID
    var outcome: Outcome
    var detail: String

    enum Outcome: String, Codable {
        case logged
        case stopped
        case failed
        case dismissed
        case processEnded

        var label: String {
            switch self {
            case .logged: "Logged"
            case .stopped: "Stopped"
            case .failed: "Failed"
            case .dismissed: "Dismissed"
            case .processEnded: "Ended"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, processName, pid, ruleID, outcome, detail
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        processName: String,
        pid: Int32,
        ruleID: UUID,
        outcome: Outcome,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.processName = processName
        self.pid = pid
        self.ruleID = ruleID
        self.outcome = outcome
        self.detail = detail
    }

    /// Hand-written so a payload written by another build still decodes: the
    /// synthesized decoder ignores property defaults and hard-fails on any key it
    /// does not find, which would make one added field destroy the whole log.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? ""
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        outcome = (try? container.decode(Outcome.self, forKey: .outcome)) ?? .logged
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

@MainActor
final class AutoStopRulesStore: ObservableObject {
    @Published var rules: [AutoStopRule] {
        didSet {
            normalizeRules()
            saveRules()
        }
    }
    @Published private(set) var pendingPrompts: [AutoStopPrompt] = []
    @Published private(set) var events: [AutoStopEvent]
    @Published private(set) var engineError: String?
    @Published private(set) var isEngineRunning = false
    @Published private(set) var validationError: String?
    @Published private(set) var recoveryMessages: [String] = []

    var currentPrompt: AutoStopPrompt? {
        pendingPrompts.first
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let eventsKey: String
    private let now: () -> Date
    private let inventory: any ProcessInventoryProviding
    private let eventLimit: Int
    private var handledOccurrences: Set<AutoStopOccurrence> = []
    private var reportedFailures: Set<AutoStopOccurrence> = []
    private var engineTask: Task<Void, Never>?
    private var actionHandler: ((AppProcess) async -> ProcessActionResult)?
    private var isNormalizing = false
    private var allowsRulesPersistence: Bool
    private var allowsEventsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.autoStopRules.v1",
        eventsKey: String = "TaskScope.autoStopEvents.v1",
        inventory: any ProcessInventoryProviding = SystemProcessInventory(),
        eventLimit: Int = 200,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.eventsKey = eventsKey
        self.inventory = inventory
        self.eventLimit = max(1, eventLimit)
        self.now = now
        let loadedRules = Self.loadRecovering(
            [AutoStopRule].self,
            userDefaults: userDefaults,
            key: key
        )
        let loadedEvents = Self.loadRecovering(
            [AutoStopEvent].self,
            userDefaults: userDefaults,
            key: eventsKey
        )
        // A decode failure must never lead to the unreadable payload being replaced
        // by the empty array we fell back to, so persistence stays disabled for that
        // key until the user explicitly resets it.
        allowsRulesPersistence = loadedRules.message == nil
        allowsEventsPersistence = loadedEvents.message == nil
        rules = loadedRules.value ?? []
        events = loadedEvents.value ?? []
        recoveryMessages = [loadedRules.message, loadedEvents.message].compactMap { $0 }
    }

    deinit {
        engineTask?.cancel()
    }

    var hasUnreadableData: Bool {
        !allowsRulesPersistence || !allowsEventsPersistence
    }

    /// Discards the unreadable payloads and re-enables writing. Anything the user
    /// rebuilt during the corrupt session is kept rather than thrown away.
    func resetAfterCorruption() {
        allowsRulesPersistence = true
        allowsEventsPersistence = true
        recoveryMessages = []
        saveRules()
        saveEvents()
    }

    @discardableResult
    func add(_ rule: AutoStopRule) -> Bool {
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

    func setEnabled(_ enabled: Bool, for rule: AutoStopRule) {
        var updated = rule
        updated.isEnabled = enabled
        _ = update(updated)
    }

    func duplicate(_ rule: AutoStopRule) {
        var copy = rule
        copy.id = UUID()
        copy.processName = uniqueName(basedOn: rule.processName)
        _ = add(copy)
    }

    func remove(at offsets: IndexSet) {
        let removedIDs = Set(offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
        rules.remove(atOffsets: offsets)
        handledOccurrences = handledOccurrences.filter { !removedIDs.contains($0.ruleID) }
        reportedFailures = reportedFailures.filter { !removedIDs.contains($0.ruleID) }
        pendingPrompts.removeAll { removedIDs.contains($0.rule.id) }
    }

    func remove(_ rule: AutoStopRule) {
        rules.removeAll { $0.id == rule.id }
        handledOccurrences = handledOccurrences.filter { $0.ruleID != rule.id }
        reportedFailures = reportedFailures.filter { $0.ruleID != rule.id }
        pendingPrompts.removeAll { $0.rule.id == rule.id }
    }

    func start(
        cadence: TimeInterval = 10,
        actionHandler: @escaping (AppProcess) async -> ProcessActionResult
    ) {
        self.actionHandler = actionHandler
        guard engineTask == nil else { return }
        isEngineRunning = true
        let interval = max(2, cadence)
        engineTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateNow()
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
            self?.isEngineRunning = false
        }
    }

    func restart(
        cadence: TimeInterval,
        actionHandler: @escaping (AppProcess) async -> ProcessActionResult
    ) {
        stop()
        start(cadence: cadence, actionHandler: actionHandler)
    }

    func stop() {
        engineTask?.cancel()
        engineTask = nil
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
        let result = await actionHandler?(prompt.process) ?? .rejected
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

    func clearEvents() {
        events.removeAll()
        saveEvents()
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
                guard runtime >= TimeInterval(rule.runtimeMinutes * 60),
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
                guard runtime >= TimeInterval(rule.runtimeMinutes * 60),
                      !handledOccurrences.contains(occurrence) else {
                    continue
                }

                handledOccurrences.insert(occurrence)
                let prompt = AutoStopPrompt(id: occurrence, rule: rule, process: process)
                switch rule.action {
                case .prompt:
                    pendingPrompts.append(prompt)
                case .kill:
                    let result = await actionHandler?(process) ?? .rejected
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
                    record(prompt, outcome: .logged, detail: "Runtime threshold reached.")
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

    private func record(_ prompt: AutoStopPrompt, outcome: AutoStopEvent.Outcome, detail: String) {
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
        saveEvents()
    }

    private func matches(_ rule: AutoStopRule, process: AppProcess) -> Bool {
        rule.processName.caseInsensitiveCompare(process.name) == .orderedSame
    }

    private func validated(_ rule: AutoStopRule) -> AutoStopRule? {
        var normalized = rule
        normalized.processName = rule.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.processName.isEmpty else {
            validationError = "Process name is required."
            return nil
        }
        guard normalized.runtimeMinutes > 0 else {
            validationError = "Runtime must be at least one minute."
            return nil
        }
        return normalized
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
        guard allowsRulesPersistence, let data = try? JSONEncoder().encode(rules) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func saveEvents() {
        guard allowsEventsPersistence, let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: eventsKey)
    }

    private static func loadRecovering<T: Decodable>(
        _ type: T.Type,
        userDefaults: UserDefaults,
        key: String
    ) -> (value: T?, message: String?) {
        guard let data = userDefaults.data(forKey: key) else { return (nil, nil) }
        do {
            return (try JSONDecoder().decode(type, from: data), nil)
        } catch {
            let backupKey = "\(key).corruptBackup"
            // Never clobber an earlier backup: a second unreadable read would
            // otherwise destroy the only surviving copy of the original data.
            if userDefaults.data(forKey: backupKey) == nil {
                userDefaults.set(data, forKey: backupKey)
            }
            return (nil, "Unreadable data was backed up as \(backupKey).")
        }
    }
}
