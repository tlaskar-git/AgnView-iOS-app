import Foundation

/// What a connected session can do. LAN gives the full HTTP API.
/// iroh carries the console log stream only.
enum Capability: Hashable, CaseIterable {
    case consoleStream
    case dispatch
    case usage
    case jobs
    case sessions
}

/// The rung a session landed on.
enum TransportRoute: String, Equatable, CaseIterable {
    case lan
    case direct
    case relay

    /// Maps the hub's `transport` field (hello and ping frames).
    /// Returns nil for a value the app does not know.
    init?(hubValue: String?) {
        switch hubValue {
        case "lan": self = .lan
        case "iroh-direct": self = .direct
        case "iroh-relay": self = .relay
        default: return nil
        }
    }
}

enum TransportError: Error, Equatable {
    case unauthorised
    case rateLimited
    case unreachable
    case protocolViolation
    case timedOut
    case unavailable
}

/// The parts of a pairing that the transports need. Package C adapts the
/// pairing payload to this protocol.
protocol HubEndpoint {
    var lanHost: String { get }
    var lanPort: Int { get }
    var key: Data { get }
    var irohTicket: String? { get }
    var isLoopbackLAN: Bool { get }
}

extension HubEndpoint {
    /// The token string the hub compares: base64url of the key, no padding.
    var token: String { HubToken.encode(key) }
}

enum HubToken {
    static func encode(_ key: Data) -> String {
        key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

protocol Transport {
    func connect() async throws -> HubSession
}

protocol HubSession: AnyObject {
    var route: TransportRoute { get }
    var capabilities: Set<Capability> { get }
    var frames: AsyncThrowingStream<ConsoleFrame, Error> { get }
    func close() async
}

extension Set where Element == Capability {
    static var lan: Set<Capability> { Set(Capability.allCases) }
    static var iroh: Set<Capability> { [.consoleStream] }
}
