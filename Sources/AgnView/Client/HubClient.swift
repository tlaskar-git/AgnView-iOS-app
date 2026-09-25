import Foundation

/// Typed calls to the hub HTTP API over the LAN. Every request carries the
/// X-AgnView-Token header. Failures map to TransportError: 401 gives
/// .unauthorised, 429 gives .rateLimited and a network error gives
/// .unreachable (or .timedOut). A body that does not decode gives
/// .protocolViolation.
final class HubClient {
    private let transport: LANTransport

    let baseURL: URL?

    private let droppedLock = NSLock()
    private var droppedCount = 0

    /// List elements the hub sent that could not be read and were left out,
    /// summed over every list call so far.
    var droppedElements: Int { droppedLock.withLock { droppedCount } }

    private func record(dropped: Int) {
        guard dropped > 0 else { return }
        droppedLock.withLock { droppedCount += dropped }
    }

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
        try HubJSON.decode(MobileStatus.self, from: try await transport.get(HubPath.status))
    }

    func usageAccounts() async throws -> [UsageAccount] {
        let list = try HubList.decode(UsageAccount.self, from: try await transport.get(HubPath.usageAccounts))
        record(dropped: list.dropped)
        return list.items
    }

    func jobs() async throws -> [Job] {
        let list = try HubList.decode(Job.self, from: try await transport.get(HubPath.jobs))
        record(dropped: list.dropped)
        return list.items
    }

    func liveSessions() async throws -> [LiveSession] {
        let list = try HubList.decode(LiveSession.self, from: try await transport.get(HubPath.liveSessions))
        record(dropped: list.dropped)
        return list.items
    }

    func dispatch(_ request: DispatchRequest) async throws -> DispatchResponse {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw TransportError.protocolViolation
        }
        let data = try await transport.post(HubPath.dispatch, json: body)
        if data.isEmpty { return DispatchResponse() }
        return try HubJSON.decode(DispatchResponse.self, from: data)
    }
}
