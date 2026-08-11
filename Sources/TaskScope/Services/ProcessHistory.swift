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
    private var samplingGeneration = 0

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
        let generation = samplingGeneration
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleNow(for: generation)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        samplingGeneration &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        state = .paused
    }

    func sampleNow() async {
        await sampleNow(for: samplingGeneration)
    }

    private func sampleNow(for generation: Int) async {
        let result = await inventory.load(fetchExtendedStats: false)
        guard generation == samplingGeneration, !Task.isCancelled else { return }

        switch result {
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
