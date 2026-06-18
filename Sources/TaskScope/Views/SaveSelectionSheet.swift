import SwiftUI

struct SaveSelectionSheet: View {
    @Binding var name: String
    let count: Int
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Selection").font(.headline)
            Text("Save \(count) selected processes as a named selection for quick recall.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Selection name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
