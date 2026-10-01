import Foundation

enum GlobalProtectDisconnectResult: Equatable, Sendable {
    case disconnected
    case failed(String)
}

enum GlobalProtectConnectionState: Equatable, Sendable {
    case connected
    case disconnected
    case busy
    case unavailable
}

/// An Error tooltip alone is ambiguous. The vendor's Connection Failed view
/// with an enabled Connect control and no Disconnect control is an idle VPN.
struct GlobalProtectConnectionObservation {
    var status: String?
    var showsConnectionFailed = false
    var canConnect = false
    var hasDisconnect = false

    var state: GlobalProtectConnectionState {
        switch status {
        case "Not Connected": .disconnected
        case "Connected": .connected
        case "Connecting...", "Disconnecting...": .busy
        case "Error" where showsConnectionFailed && canConnect && !hasDisconnect: .disconnected
        default: .unavailable
        }
    }
}

protocol GlobalProtectDisconnectRuntime: Sendable {
    func connectionState() async -> GlobalProtectConnectionState
    func pressDisconnect() async -> Bool
    func waitForNextObservation() async
}

/// Never shuts down the service on a timeout, failed click, or an unknown state.
/// Consecutive disconnected observations give the vendor time to restore DNS.
enum GlobalProtectDisconnectController {
    static func disconnect(
        using runtime: any GlobalProtectDisconnectRuntime,
        observationLimit: Int = 60
    ) async -> GlobalProtectDisconnectResult {
        var requested = false
        var disconnectedObservations = 0
        var unavailableObservations = 0
        for _ in 0..<observationLimit {
            guard !Task.isCancelled else {
                return .failed("GlobalProtect shutdown was cancelled before its services were stopped.")
            }
            let state = await runtime.connectionState()
            if state != .unavailable { unavailableObservations = 0 }
            switch state {
            case .disconnected:
                disconnectedObservations += 1
                if disconnectedObservations >= 5 { return .disconnected }
            case .connected:
                disconnectedObservations = 0
                if !requested {
                    guard await runtime.pressDisconnect() else {
                        return .failed("GlobalProtect's Disconnect control is unavailable. Its services were left running.")
                    }
                    requested = true
                }
            case .busy:
                disconnectedObservations = 0
            case .unavailable:
                disconnectedObservations = 0
                unavailableObservations += 1
                // A menu can disappear during a focus change. Give the runtime
                // a bounded chance to reopen it; unreadable state is never idle.
                if unavailableObservations >= 3 {
                    return .failed("TaskScope could not verify GlobalProtect's connection state. Its services were left running.")
                }
            }
            await runtime.waitForNextObservation()
        }
        return .failed("GlobalProtect did not finish disconnecting. Complete any request in GlobalProtect and try Quit All again; its services were left running.")
    }
}
