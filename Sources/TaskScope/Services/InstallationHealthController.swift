import Foundation

@MainActor
final class InstallationHealthController: ObservableObject {
    @Published private(set) var report: InstallationHealthReport?
    @Published private(set) var isRefreshing = false
    @Published private(set) var invalidated = true
    @Published private(set) var actionMessage: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private let collect: (InstallationHealthInput) async -> InstallationHealthReport
    private let availableRecoveries: @MainActor () -> Set<InstallationHealthReport.Recovery>
    private let performRecovery: @MainActor (InstallationHealthReport.Recovery) async -> Bool
    private let now: () -> Date

    init(
        collect: @escaping (InstallationHealthInput) async -> InstallationHealthReport = {
            await InstallationHealthRuntime.live.collect($0)
        },
        availableRecoveries: @escaping @MainActor () -> Set<InstallationHealthReport.Recovery> = { InstallationHealthRecovery.available() },
        performRecovery: @escaping @MainActor (InstallationHealthReport.Recovery) async -> Bool = { await InstallationHealthRecovery.perform($0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.collect = collect
        self.availableRecoveries = availableRecoveries
        self.performRecovery = performRecovery
        self.now = now
    }

    deinit { task?.cancel() }

    func refresh(_ input: InstallationHealthInput) {
        invalidate()
        actionMessage = nil
        isRefreshing = true
        let token = generation
        let collect = collect
        task = Task { [weak self] in
            let result = await collect(input)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.report = result
            self.invalidated = false
            self.isRefreshing = false
        }
    }

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
        invalidated = true
        isRefreshing = false
    }

    @discardableResult
    func recover(_ action: InstallationHealthReport.Recovery) async -> Bool {
        guard let report, !invalidated, !isRefreshing, report.isFresh(at: now()),
              report.findings.contains(where: { $0.recovery == action }),
              availableRecoveries().contains(action) else {
            actionMessage = "This recovery target or result is no longer verified. Refresh Health to check again."
            invalidate()
            return false
        }
        // Invalidate before yielding, so repeated clicks cannot reuse evidence.
        invalidate()
        let succeeded = await performRecovery(action)
        actionMessage = succeeded
            ? "Navigation requested. Refresh Health after reviewing the destination; no repair is assumed."
            : "The verified destination could not be opened. Refresh Health and try again."
        return succeeded
    }
}
