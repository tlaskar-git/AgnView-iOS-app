import Foundation

/// Where the connection to the active hub stands.
enum ConnectionState: Equatable {
    case connecting
    case online(TransportRoute, Set<Capability>)
    /// `retryIn` is the delay before the next attempt, or nil when the model
    /// waits for the user (no hub, or a forced state).
    case offline(retryIn: Duration?)
    /// The hub rejected a key that never worked. Pair again.
    case authFailed
    /// The hub rejected a key that worked before. The key was regenerated.
    case keyRevoked

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}
