import SwiftUI

struct QuickWatchedPresetDraft: Identifiable, Equatable {
    let id = UUID()
    var processes: [AppProcess]
}

struct QuickAutoStopRuleSheet: View {
    let process: AppProcess
    let existingRule: AutoStopRule?
    let onSave: (String, Int, AutoStopRule.Action) -> Void
    let onCancel: () -> Void

    @State private var processName: String
    @State private var runtimeMinutes: Int
    @State private var action: AutoStopRule.Action

    init(
        process: AppProcess,
        existingRule: AutoStopRule?,
        onSave: @escaping (String, Int, AutoStopRule.Action) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.process = process
        self.existingRule = existingRule
        self.onSave = onSave
        self.onCancel = onCancel
        _processName = State(initialValue: existingRule?.processName ?? process.name)
        _runtimeMinutes = State(initialValue: existingRule?.runtimeMinutes ?? 5)
        _action = State(initialValue: existingRule?.action ?? .prompt)
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
                TextField("Process name", text: $processName)

                Stepper(value: $runtimeMinutes, in: 1...240, step: 1) {
                    HStack {
                        Text("Runtime minutes")
                        Spacer()
                        Text("\(runtimeMinutes)")
                            .monospacedDigit()
                    }
                }

                Picker("Action", selection: $action) {
                    ForEach(AutoStopRule.Action.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(process.displayCommand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(existingRule == nil ? "Add Rule" : "Update Rule") {
                    onSave(processName, runtimeMinutes, action)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 300)
    }
}

struct QuickWatchedPresetSheet: View {
    let draft: QuickWatchedPresetDraft
    let onSave: (WatchedAppPreset) -> Void
    let onCancel: () -> Void

    @State private var displayName: String
    @State private var mainProcessName: String
    @State private var helperNames: String
    @State private var appPath: String

    init(
        draft: QuickWatchedPresetDraft,
        onSave: @escaping (WatchedAppPreset) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let names = Self.uniqueNames(from: draft.processes)
        let mainName = names.first ?? ""

        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: mainName)
        _mainProcessName = State(initialValue: mainName)
        _helperNames = State(initialValue: names.dropFirst().joined(separator: ", "))
        _appPath = State(initialValue: Self.inferredAppPath(for: draft.processes.first, fallbackName: mainName))
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
                TextField("Display name", text: $displayName)
                TextField("Main process name", text: $mainProcessName)
                TextField("Helpers", text: $helperNames)
                TextField("App path", text: $appPath)
            }
            .formStyle(.grouped)

            HStack {
                Text(includedProcessSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Add Preset") {
                    onSave(buildPreset())
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
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

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func buildPreset() -> WatchedAppPreset {
        let trimmedMain = mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let helpers = parseList(helperNames).filter {
            $0.caseInsensitiveCompare(trimmedMain) != .orderedSame
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

    private func parseList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    static func inferredAppPath(for process: AppProcess?, fallbackName: String) -> String {
        guard let process else { return "/Applications/\(fallbackName).app" }

        let executablePath = process.executablePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let range = executablePath.range(of: ".app", options: [.caseInsensitive]) {
            return String(executablePath[..<range.upperBound])
        }

        return "/Applications/\(process.name).app"
    }
}
