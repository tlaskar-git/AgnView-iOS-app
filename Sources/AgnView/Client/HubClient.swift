import Foundation

/// Typed calls to the hub API over any APITransport: HTTP on the LAN or one
/// stream per call over iroh. On the LAN every request carries the
/// X-AgnView-Token header. Failures map to TransportError: 401 gives
/// .unauthorised, 429 gives .rateLimited and a network error gives
/// .unreachable (or .timedOut). A body that does not decode gives
/// .protocolViolation.
final class HubClient {
    private let api: APITransport

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
        self.api = LANAPITransport(lan: LANTransport(baseURL: baseURL, token: token, session: session,
                                                     requestTimeout: requestTimeout))
    }

    /// A client over the API route a session offers (iroh).
    init(api: APITransport) {
        self.baseURL = nil
        self.api = api
    }

    private func get(_ path: String) async throws -> Data {
        try await call("GET", path, body: nil)
    }

    private func call(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let response = try await api.send(method: method, path: path, body: body)
        if let failure = LANTransport.map(status: response.status) { throw failure }
        return response.body
    }

    convenience init(endpoint: HubEndpoint, session: URLSession = .shared) {
        self.init(baseURL: LANTransport.baseURL(host: endpoint.lanHost, port: endpoint.lanPort),
                  token: endpoint.token, session: session)
    }

    func status() async throws -> MobileStatus {
        try HubJSON.decode(MobileStatus.self, from: try await get(HubPath.status))
    }

    func usageAccounts() async throws -> [UsageAccount] {
        let list = try HubList.decode(UsageAccount.self, from: try await get(HubPath.usageAccounts))
        record(dropped: list.dropped)
        return list.items
    }

    func jobs() async throws -> [Job] {
        let list = try HubList.decode(Job.self, from: try await get(HubPath.jobs))
        record(dropped: list.dropped)
        return list.items
    }

    func liveSessions() async throws -> [LiveSession] {
        let list = try HubList.decode(LiveSession.self, from: try await get(HubPath.liveSessions))
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
        let data = try await call("POST", HubPath.dispatch, body: body)
        if data.isEmpty { return DispatchResponse() }
        return try HubJSON.decode(DispatchResponse.self, from: data)
    }
}
