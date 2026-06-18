import Foundation

@MainActor
final class ProcessHistory: ObservableObject {
    struct Sample: Equatable {
        var timestamp: Date
        var systemCPU: Double
        var systemMemoryMB: Double
    }

    @Published private(set) var samples: [Sample] = []
    private let maxSamples = 60
    private var lastSampled: Date?

    func record(processes: [AppProcess]) {
        let now = Date()
        if let last = lastSampled, now.timeIntervalSince(last) < 1.0 { return }
        lastSampled = now

        let cpu = processes.reduce(0.0) { $0 + $1.cpu }
        let mem = processes.reduce(0.0) { $0 + $1.memoryMB }
        samples.append(Sample(timestamp: now, systemCPU: cpu, systemMemoryMB: mem))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
