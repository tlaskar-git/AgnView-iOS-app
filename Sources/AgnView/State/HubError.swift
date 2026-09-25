import Foundation

/// Thrown by AppModel.dispatch when the connection has no dispatch capability.
struct DispatchUnavailable: Error, Equatable, LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Errors from AppModel calls that need a live hub.
enum HubError: Error, Equatable, LocalizedError {
    case notConnected
    case transport(TransportError)

    var errorDescription: String? {
        switch self {
        case .notConnected, .transport(.unreachable), .transport(.timedOut), .transport(.unavailable):
            return UserMessages.offlineHub
        case .transport(.unauthorised):
            return UserMessages.authFailed
        case .transport(.rateLimited):
            return "The hub is busy. Try again in a moment."
        case .transport(.notSupported):
            return UserMessages.hubNeedsUpdate
        case .transport(.protocolViolation):
            return "The hub sent an answer this app does not understand."
        }
    }
}

/// What a transport failure means for the connection state.
enum FailureOutcome: Equatable {
    case authFailed
    case keyRevoked
    case offline

    /// 401 (or the iroh unauthorised frame) is authFailed when the hub never
    /// accepted this key and keyRevoked when it did. Everything else, 429
    /// included, is offline with a retry timer.
    static func classify(_ error: TransportError, everConnected: Bool) -> FailureOutcome {
        switch error {
        case .unauthorised: return everConnected ? .keyRevoked : .authFailed
        default: return .offline
        }
    }
}
