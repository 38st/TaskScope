import SwiftUI

struct SparklineView: View {
    var samples: [ProcessHistory.Sample]
    var keyPath: KeyPath<ProcessHistory.Sample, Double>
    var color: Color
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                guard samples.count > 1 else { return }
                let values = samples.map { $0[keyPath: keyPath] }
                guard let max = values.max(), max > 0 else { return }
                let stepX = size.width / CGFloat(values.count - 1)
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = size.height - (CGFloat(value) / CGFloat(max)) * size.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
            .frame(height: 24)
        }
    }
}
