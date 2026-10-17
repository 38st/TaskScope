import Darwin
import SwiftUI

struct QuickWatchedPresetDraft: Identifiable, Equatable {
    let id = UUID()
    var processes: [AppProcess]

    func validationError(
        for preset: WatchedAppPreset,
        currentUID: uid_t = getuid(),
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String? {
        guard !processes.isEmpty else { return "Select at least one process to watch." }
        let builder = WatchedSnapshotBuilder(excludedPID: currentPID, currentUID: currentUID)
        var hasMainProcess = false
        for process in processes {
            guard process.pid != currentPID else { return "TaskScope cannot watch itself." }
            guard process.uid == currentUID else {
                return "\(process.name) is not owned by the current user. Choose processes owned by your account."
            }
            guard process.executablePath != nil else {
                return "\(process.name) has no trusted executable path, so this preset cannot watch it."
            }
            let snapshot = builder.snapshot(for: preset, in: [process])
            guard !snapshot.runningNames.isEmpty else {
                return "\(process.name) cannot match this preset. The main process must be inside the app's Contents/MacOS folder, and each helper inside the same app's Contents folder, with matching process names."
            }
            hasMainProcess = hasMainProcess || snapshot.isMainRunning
        }
        return hasMainProcess ? nil : "Choose a main process from the app's Contents/MacOS folder. App extensions and XPC services can only be included as helpers of their containing app."
    }
}

@MainActor
final class QuickAutoStopRuleFormState: ObservableObject {
    @Published var processName: String
    @Published var runtimeMinutes: Int
    @Published var action: AutoStopRule.Action
    @Published var validationError: String?

    init(processName: String, runtimeMinutes: Int, action: AutoStopRule.Action) {
        self.processName = processName
        self.runtimeMinutes = runtimeMinutes
        self.action = action
    }
}

@MainActor
final class QuickWatchedPresetFormState: ObservableObject {
    @Published var displayName: String
    @Published var mainProcessName: String
    @Published var helperNames: String
    @Published var appPath: String
    @Published var validationError: String?

    init(
        displayName: String,
        mainProcessName: String,
        helperNames: String,
        appPath: String
    ) {
        self.displayName = displayName
        self.mainProcessName = mainProcessName
        self.helperNames = helperNames
        self.appPath = appPath
    }

    var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func buildPreset() -> WatchedAppPreset {
        let trimmedMain = mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let helpers = helperNames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && $0.caseInsensitiveCompare(trimmedMain) != .orderedSame
            }
        let trimmedPath = appPath.trimmingCharacters(in: .whitespacesAndNewlines)

        return WatchedAppPreset(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            mainProcessName: trimmedMain,
            helperProcessNames: helpers,
            protectedProcessNames: [],
            appPath: trimmedPath
        )
    }
}

/// Saves the quick auto-stop sheet's draft honouring the mode the sheet was
/// opened in. In Create mode a typed name that collides with an existing rule is
/// refused rather than silently rewriting that rule with a different process's
/// executable path.
@MainActor
enum QuickAutoStopRuleSaver {
    struct Outcome: Equatable {
        var error: String?
        var statusMessage: String?
    }

    static func existingRule(for process: AppProcess, in rules: AutoStopRulesStore) -> AutoStopRule? {
        rules.rules.first { $0.processName.caseInsensitiveCompare(process.name) == .orderedSame }
    }

    static func executablePath(
        processName: String,
        observedProcessName: String,
        observedExecutablePath: String?,
        action: AutoStopRule.Action,
        existingRule: AutoStopRule?
    ) -> String? {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The observed path identifies the right-clicked process only.
        let observedPath = trimmedName.caseInsensitiveCompare(observedProcessName) == .orderedSame
            ? observedExecutablePath
            : nil
        guard let existing = existingRule else { return observedPath }
        // Keep a name-wide rule's scope unless Auto Stop requires a path.
        return existing.executablePath == nil && action != .kill
            ? nil
            : observedPath ?? existing.executablePath
    }

    static func enablesDisabledRule(
        existingRule: AutoStopRule?,
        action: AutoStopRule.Action,
        executablePath: String?
    ) -> Bool {
        guard let existing = existingRule else { return false }
        return !existing.isEnabled && existing.action == .kill && existing.executablePath == nil
            && action == .kill && executablePath != nil
    }

    static func save(
        into rules: AutoStopRulesStore,
        processName: String,
        observedProcessName: String,
        observedExecutablePath: String?,
        runtimeMinutes: Int,
        action: AutoStopRule.Action,
        existingRule: AutoStopRule?
    ) -> Outcome {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return Outcome(error: "Process name is required.")
        }
        let executablePath = executablePath(
            processName: trimmedName,
            observedProcessName: observedProcessName,
            observedExecutablePath: observedExecutablePath,
            action: action,
            existingRule: existingRule
        )

        if let existing = existingRule {
            let enablesRule = enablesDisabledRule(existingRule: existing, action: action, executablePath: executablePath)
            let isEnabled = existing.isEnabled || enablesRule
            guard rules.update(AutoStopRule(
                id: existing.id,
                processName: trimmedName,
                executablePath: executablePath,
                runtimeMinutes: runtimeMinutes,
                action: action,
                isEnabled: isEnabled
            )) else {
                return Outcome(error: rules.validationError ?? "The auto-stop rule could not be updated.")
            }
            return Outcome(statusMessage: enablesRule
                ? "Enabled auto-stop rule for \(trimmedName)."
                : "Updated \(isEnabled ? "" : "disabled ")auto-stop rule for \(trimmedName).")
        }

        if let collision = rules.rules.first(where: {
            $0.processName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            return Outcome(
                error: "An auto-stop rule for \(collision.processName) already exists. Right-click a process named \(collision.processName) to update it."
            )
        }
        guard rules.add(AutoStopRule(
            processName: trimmedName,
            executablePath: executablePath,
            runtimeMinutes: runtimeMinutes,
            action: action
        )) else {
            return Outcome(error: rules.validationError ?? "The auto-stop rule could not be added.")
        }
        return Outcome(statusMessage: "Added auto-stop rule for \(trimmedName).")
    }
}

struct QuickAutoStopRuleSheet: View {
    let process: AppProcess
    let existingRule: AutoStopRule?
    let onSave: (String, Int, AutoStopRule.Action) -> String?
    let onCancel: () -> Void

    @StateObject private var form: QuickAutoStopRuleFormState

    init(
        process: AppProcess,
        existingRule: AutoStopRule?,
        onSave: @escaping (String, Int, AutoStopRule.Action) -> String?,
        onCancel: @escaping () -> Void,
        form: QuickAutoStopRuleFormState? = nil
    ) {
        self.process = process
        self.existingRule = existingRule
        self.onSave = onSave
        self.onCancel = onCancel
        _form = StateObject(
            wrappedValue: form ?? QuickAutoStopRuleFormState(
                processName: existingRule?.processName ?? process.name,
                runtimeMinutes: existingRule?.runtimeMinutes ?? 5,
                action: existingRule?.action ?? .prompt
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(existingRule == nil ? "Create Auto-Stop Rule" : "Update Auto-Stop Rule")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                TextField("Process name", text: $form.processName)

                Stepper(
                    value: $form.runtimeMinutes,
                    in: 1...AutoStopRulesStore.maximumRuntimeMinutes,
                    step: 1
                ) {
                    HStack {
                        Text("Runtime minutes")
                        Spacer()
                        Text("\(form.runtimeMinutes)")
                            .monospacedDigit()
                    }
                }

                Picker("Action", selection: $form.action) {
                    ForEach(AutoStopRule.Action.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Executable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(executablePath ?? "Any process named \(form.processName.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if QuickAutoStopRuleSaver.enablesDisabledRule(
                        existingRule: existingRule, action: form.action, executablePath: executablePath
                    ) {
                        Text("Saving enables this Auto Stop rule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if form.action == .kill, executablePath == nil {
                        Text("Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let validationError = form.validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Could not save rule: \(validationError)")
            }

            HStack {
                Text(process.displayCommand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(existingRule == nil ? "Add Rule" : "Update Rule") {
                    form.validationError = onSave(
                        form.processName,
                        form.runtimeMinutes,
                        form.action
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(form.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    private var executablePath: String? {
        QuickAutoStopRuleSaver.executablePath(
            processName: form.processName,
            observedProcessName: process.name,
            observedExecutablePath: process.executablePath,
            action: form.action,
            existingRule: existingRule
        )
    }
}

struct QuickWatchedPresetSheet: View {
    let draft: QuickWatchedPresetDraft
    let onSave: (WatchedAppPreset) -> String?
    let onCancel: () -> Void

    @StateObject private var form: QuickWatchedPresetFormState

    init(
        draft: QuickWatchedPresetDraft,
        onSave: @escaping (WatchedAppPreset) -> String?,
        onCancel: @escaping () -> Void,
        form: QuickWatchedPresetFormState? = nil
    ) {
        let names = Self.uniqueNames(from: draft.processes)
        let mainName = names.first ?? ""

        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _form = StateObject(
            wrappedValue: form
                ?? QuickWatchedPresetFormState(
                    displayName: mainName,
                    mainProcessName: mainName,
                    helperNames: names.dropFirst().joined(separator: ", "),
                    appPath: Self.inferredAppPath(
                        for: draft.processes.first,
                        fallbackName: mainName
                    )
                )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create Watched Preset")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                TextField("Display name", text: $form.displayName)
                TextField("Main process name", text: $form.mainProcessName)
                TextField("Helpers", text: $form.helperNames)
                TextField("App path", text: $form.appPath)
            }
            .formStyle(.grouped)

            if let validationError = form.validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Could not save preset: \(validationError)")
            }

            HStack {
                Text(includedProcessSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Add Preset") {
                    guard let preset = WatchedAppsStore.validatedPresets([form.buildPreset()]).presets.first else {
                        form.validationError = "Enter a valid app preset with an absolute .app bundle path. Non-bundled tools cannot be watched as apps."
                        return
                    }
                    if let error = draft.validationError(for: preset) {
                        form.validationError = error
                        return
                    }
                    form.validationError = onSave(preset)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canSave)
            }
        }
        .padding(20)
        .frame(width: 460, height: 320)
    }

    private var includedProcessSummary: String {
        let names = Self.uniqueNames(from: draft.processes)
        guard !names.isEmpty else { return "No processes selected" }
        return names.joined(separator: ", ")
    }

    private static func uniqueNames(from processes: [AppProcess]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []

        for process in processes {
            let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }

        return names
    }

    /// The bundle is the last path *component* ending in `.app`, bounded by a
    /// separator or the end of the string. A substring match would stop at
    /// `/Users/me/my.apps/Tool` or at `Foo.application`.
    static func inferredAppPath(for process: AppProcess?, fallbackName: String) -> String {
        guard let process else { return "" }

        let executablePath = process.executablePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        if let bundleIndex = components.lastIndex(where: {
            $0.count > ".app".count && $0.lowercased().hasSuffix(".app")
        }) {
            return components[...bundleIndex].joined(separator: "/")
        }

        return ""
    }
}
