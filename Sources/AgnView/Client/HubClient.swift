import Foundation

/// Typed calls to the hub HTTP API over the LAN. Every request carries the
/// X-AgnView-Token header. Failures map to TransportError: 401 gives
/// .unauthorised, 429 gives .rateLimited and a network error gives
/// .unreachable (or .timedOut). A body that does not decode gives
/// .protocolViolation.
final class HubClient {
    private let transport: LANTransport

    let baseURL: URL?

    init(baseURL: URL?, token: String, session: URLSession = .shared, requestTimeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.transport = LANTransport(baseURL: baseURL, token: token, session: session,
                                      requestTimeout: requestTimeout)
    }

    convenience init(endpoint: HubEndpoint, session: URLSession = .shared) {
        self.init(baseURL: LANTransport.baseURL(host: endpoint.lanHost, port: endpoint.lanPort),
                  token: endpoint.token, session: session)
    }

    func status() async throws -> MobileStatus {
        try HubJSON.decode(MobileStatus.self, from: try await transport.get(Endpoint.status))
    }

    func usageAccounts() async throws -> [UsageAccount] {
        try HubJSON.decode([UsageAccount].self, from: try await transport.get(Endpoint.usageAccounts))
    }

    func jobs() async throws -> [Job] {
        try HubJSON.decode([Job].self, from: try await transport.get(Endpoint.jobs))
    }

    func liveSessions() async throws -> [LiveSession] {
        try HubJSON.decode([LiveSession].self, from: try await transport.get(Endpoint.liveSessions))
    }

    func dispatch(_ request: DispatchRequest) async throws -> DispatchResponse {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw TransportError.protocolViolation
        }
        let data = try await transport.post(Endpoint.dispatch, json: body)
        if data.isEmpty { return DispatchResponse() }
        return try HubJSON.decode(DispatchResponse.self, from: data)
    }
}
