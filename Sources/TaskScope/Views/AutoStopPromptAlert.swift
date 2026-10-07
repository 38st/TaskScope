import SwiftUI

struct AutoStopPromptAlert: View {
    let prompt: AutoStopPrompt?
    let rules: AutoStopRulesStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(
                prompt.map { "Auto-Stop: \($0.process.name)" } ?? "Auto-Stop",
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { isPresented in
                        // A button may already have consumed this prompt. Never
                        // dismiss the next queue entry during alert write-back.
                        if !isPresented, let prompt { rules.dismissPrompt(prompt) }
                    }
                ),
                presenting: prompt
            ) { prompt in
                Button("Stop Now", role: .destructive) {
                    guard let claimed = rules.claimPrompt(prompt) else { return }
                    Task { await rules.finishStop(claimed) }
                }
                Button("Dismiss", role: .cancel) {
                    rules.dismissPrompt(prompt)
                }
            } message: { prompt in
                Text("\(prompt.process.name) (PID \(prompt.process.pid)) has run for \(prompt.process.elapsedTime), beyond the \(prompt.rule.runtimeMinutes)-minute rule. Stop it now?")
            }
    }
}
