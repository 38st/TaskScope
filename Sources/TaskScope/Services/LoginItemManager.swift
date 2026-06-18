import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }

            message = enabled ? "Launch at Login on." : "Launch at Login off."
            refreshAfterDelay()
        } catch {
            refresh()
            message = "Could not update login item."
        }
    }

    private func refreshAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            refresh()
        }
    }
}
