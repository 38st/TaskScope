import SwiftUI

struct QuickWatchedPresetDraft: Identifiable, Equatable {
    let id = UUID()
    var processes: [AppProcess]
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
            appPath: trimmedPath.isEmpty ? "/Applications/\(trimmedMain).app" : trimmedPath
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

    static func save(
        into rules: AutoStopRulesStore,
        processName: String,
        observedExecutablePath: String?,
        runtimeMinutes: Int,
        action: AutoStopRule.Action,
        existingRule: AutoStopRule?
    ) -> Outcome {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return Outcome(error: "Process name is required.")
        }

        if let existing = existingRule {
            guard rules.update(AutoStopRule(
                id: existing.id,
                processName: trimmedName,
                executablePath: observedExecutablePath ?? existing.executablePath,
                runtimeMinutes: runtimeMinutes,
                action: action,
                isEnabled: existing.isEnabled
            )) else {
                return Outcome(error: rules.validationError ?? "The auto-stop rule could not be updated.")
            }
            return Outcome(statusMessage: "Updated auto-stop rule for \(trimmedName).")
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
            executablePath: observedExecutablePath,
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
        .frame(width: 420, height: 300)
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
                    form.validationError = onSave(form.buildPreset())
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
        guard let process else { return "/Applications/\(fallbackName).app" }

        let executablePath = process.executablePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        if let bundleIndex = components.lastIndex(where: {
            $0.count > ".app".count && $0.lowercased().hasSuffix(".app")
        }) {
            return components[...bundleIndex].joined(separator: "/")
        }

        return "/Applications/\(process.name).app"
    }
}
