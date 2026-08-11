import SwiftUI

struct AutoStopRuleEditorSheet: View {
    @State private var draft: AutoStopRule
    let onSave: (AutoStopRule) -> Void
    let onCancel: () -> Void

    init(
        rule: AutoStopRule,
        onSave: @escaping (AutoStopRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Auto-Stop Rule")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Process name", text: $draft.processName)
                .textFieldStyle(.roundedBorder)

            Stepper(value: $draft.runtimeMinutes, in: 1...1440) {
                Text("Runtime: \(draft.runtimeMinutes) minute\(draft.runtimeMinutes == 1 ? "" : "s")")
            }

            Picker("Action", selection: $draft.action) {
                ForEach(AutoStopRule.Action.allCases) { action in
                    Text(action.label).tag(action)
                }
            }

            Toggle("Enabled", isOn: $draft.isEnabled)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
