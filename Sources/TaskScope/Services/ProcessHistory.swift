import Foundation

@MainActor
final class ProcessHistory: ObservableObject {
    struct Sample: Equatable {
        var timestamp: Date
        var observedProcessCPU: Double
        var observedProcessMemoryMB: Double
        var processCount: Int
    }

    enum SamplingState: Equatable {
        case paused
        case sampling
        case unavailable(String)

        var label: String {
            switch self {
            case .paused: "Paused"
            case .sampling: "Live"
            case .unavailable: "Unavailable"
            }
        }
    }

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var state: SamplingState = .paused

    private let inventory: any ProcessInventoryProviding
    private let now: () -> Date
    private let maxSamples: Int
    private var samplingTask: Task<Void, Never>?

    init(
        inventory: any ProcessInventoryProviding = SystemProcessInventory(),
        maxSamples: Int = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.inventory = inventory
        self.maxSamples = max(2, maxSamples)
        self.now = now
    }

    deinit {
        samplingTask?.cancel()
    }

    func start(cadence: TimeInterval) {
        stop()
        state = .sampling
        let interval = max(2, cadence)
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleNow()
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        state = .paused
    }

    func sampleNow() async {
        switch await inventory.load(fetchExtendedStats: false) {
        case .failure(let error):
            state = .unavailable(error.localizedDescription)
        case .success(let processes):
            record(processes: processes)
            state = .sampling
        }
    }

    func record(processes: [AppProcess]) {
        let cpu = processes.reduce(0.0) { $0 + $1.cpu }
        let memory = processes.reduce(0.0) { $0 + $1.memoryMB }
        samples.append(
            Sample(
                timestamp: now(),
                observedProcessCPU: cpu,
                observedProcessMemoryMB: memory,
                processCount: processes.count
            )
        )
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}
