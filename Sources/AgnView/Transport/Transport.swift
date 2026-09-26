import Foundation

/// What a connected session can do. LAN gives the full HTTP API. iroh gives
/// the console log stream, and the mobile API too when the hub says so in its
/// hello frame (hub 0.1.12 or later), with pipeline create and delete from hub
/// 0.1.13.
enum Capability: Hashable, CaseIterable {
    case consoleStream
    case dispatch
    case usage
    case jobs
    case sessions
    /// GET /api/system/capabilities and /api/system/files. Hubs up to 0.1.14
    /// serve them on the LAN only, so an iroh session does not have this one.
    case catalogue
    /// POST /api/jobs and DELETE /api/jobs/{id}. LAN only in hub 0.1.12. Hub
    /// 0.1.13 added both to the iroh allowlist, see `Capability.irohJobs`.
    case manageJobs
    /// POST /api/usage/refresh-all. LAN only on every hub so far.
    case usageRefresh

    /// The capabilities the hub 0.1.12 allowlist for iroh does not include.
    static let lanOnly: Set<Capability> = [.catalogue, .manageJobs, .usageRefresh]
}

/// The names a hub puts in the hello frame's `capabilities` list.
enum HelloCapability {
    static let console = "console"
    /// The mobile API over iroh (hub 0.1.12 or later).
    static let api = "api"
    /// Phone uploads over iroh. Hub 0.1.13 added this name in the same release
    /// that put POST /api/jobs and DELETE /api/jobs/{id} on the iroh
    /// allowlist. The hub sends no version and no separate pipelines flag, so
    /// this name is the signal that the hub can create and delete pipelines
    /// over iroh. A hub that lists "api" without it is treated as 0.1.12:
    /// pipelines are created on the LAN only.
    static let uploads = "uploads"
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
    /// The hub refused the request as not part of the remote API.
    case notSupported
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

/// One answer from the hub API: the HTTP status and the JSON body.
struct APIResponse: Equatable {
    var status: Int
    var body: Data
}

/// Sends one hub API call and returns the answer. The LAN implementation uses
/// HTTP. The iroh implementation opens one stream per call.
protocol APITransport {
    func send(method: String, path: String, body: Data?) async throws -> APIResponse
}

protocol Transport {
    func connect() async throws -> HubSession
}

protocol HubSession: AnyObject {
    var route: TransportRoute { get }
    var capabilities: Set<Capability> { get }
    var frames: AsyncThrowingStream<ConsoleFrame, Error> { get }
    /// The API route this session offers, when it has one of its own. Nil
    /// means the caller builds a LAN client.
    var api: APITransport? { get }
    func close() async
}

extension HubSession {
    var api: APITransport? { nil }
}

extension Set where Element == Capability {
    static var lan: Set<Capability> { Set(Capability.allCases) }
    /// Console only: an iroh session to a hub without the remote API.
    static var iroh: Set<Capability> { [.consoleStream] }
    /// An iroh session to a hub that serves the mobile API (hub 0.1.12).
    static var irohAPI: Set<Capability> { Set(Capability.allCases).subtracting(Capability.lanOnly) }
    /// An iroh session to a hub that also creates and deletes pipelines over
    /// iroh (hub 0.1.13 or later).
    static var irohJobs: Set<Capability> { irohAPI.union([.manageJobs]) }

    /// What an iroh session can do, read from the hello frame's list.
    static func irohGranted(hello names: [String]?) -> Set<Capability> {
        let names = Set(names ?? [])
        guard names.contains(HelloCapability.api) else { return .iroh }
        return names.contains(HelloCapability.uploads) ? .irohJobs : .irohAPI
    }
}
