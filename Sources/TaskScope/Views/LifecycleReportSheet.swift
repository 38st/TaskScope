import SwiftUI

struct LifecycleReportSheet: View {
    let report: LifecycleReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.title)
                .font(.title2)
                .fontWeight(.semibold)

            List(report.jobs, id: \.label) { job in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.label)
                            .fontWeight(.medium)
                        Spacer()
                        Text(job.state.rawValue.capitalized)
                            .foregroundStyle(job.succeeded ? Color.secondary : Color.red)
                    }
                    Text(job.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 360)
    }
}
