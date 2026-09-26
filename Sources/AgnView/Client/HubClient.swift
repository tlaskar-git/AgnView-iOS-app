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

    // MARK: Composer, files and logs

    /// GET /api/system/capabilities: the model and effort lists per agent.
    func capabilities() async throws -> HubCatalogue {
        try HubJSON.decodePlain(HubCatalogue.self, from: try await get(HubPath.capabilities))
    }

    /// GET /api/system/files: files on the hub computer that can be attached.
    func files(directory: String? = nil) async throws -> WorkspaceFiles {
        var path = HubPath.files
        if let directory, !directory.isEmpty {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "cwd", value: directory)]
            if let query = components.percentEncodedQuery { path += "?" + query }
        }
        return try HubJSON.decodePlain(WorkspaceFiles.self, from: try await get(path))
    }

    /// GET /api/console/logs: the newest rows, or the rows after `afterId`.
    func logs(afterId: Int? = nil, limit: Int = 250) async throws -> [ConsoleFrame.LogEntry] {
        var path = HubPath.consoleLogs + "?agent=all&limit=\(max(1, min(limit, 1000)))"
        if let afterId { path += "&after_id=\(afterId)" }
        let list = try HubList.decode(ConsoleFrame.LogEntry.self, from: try await get(path),
                                      decoder: JSONDecoder())
        record(dropped: list.dropped)
        return list.items
    }

    // MARK: Pipelines and usage

    /// POST /api/jobs. Throws HubRejection with the hub's reason when it refuses the pipeline.
    func createJob(_ body: CreateJobBody) async throws -> Job {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw TransportError.protocolViolation
        }
        return try HubJSON.decode(Job.self, from: try await perform("POST", HubPath.jobs, body: data))
    }

    /// DELETE /api/jobs/{id}.
    func deleteJob(id: String) async throws {
        guard PipelineDraft.isSafeId(id) else { throw TransportError.protocolViolation }
        _ = try await perform("DELETE", HubPath.job(id), body: nil)
    }

    /// POST /api/tasks/{id}/request-revision.
    func requestRevision(taskId: String, feedback: String, fromAgent: String = "user") async throws {
        guard PipelineDraft.isSafeId(taskId) else { throw TransportError.protocolViolation }
        let body = try JSONSerialization.data(withJSONObject: ["feedback": feedback, "from_agent": fromAgent])
        _ = try await perform("POST", HubPath.requestRevision(task: taskId), body: body)
    }

    /// POST /api/tasks/{id}/fail. The hub needs a reason.
    func failTask(taskId: String, reason: String) async throws {
        guard PipelineDraft.isSafeId(taskId) else { throw TransportError.protocolViolation }
        let body = try JSONSerialization.data(withJSONObject: ["reason": reason])
        _ = try await perform("POST", HubPath.failTask(taskId), body: body)
    }

    /// POST /api/usage/refresh-all: the hub reads every provider again and
    /// answers with the accounts, as GET /api/usage/accounts does.
    func refreshAllUsage() async throws -> [UsageAccount] {
        let list = try HubList.decode(UsageAccount.self, from: try await perform("POST", HubPath.usageRefreshAll,
                                                                                body: Data("{}".utf8)))
        record(dropped: list.dropped)
        return list.items
    }

    /// A call whose refusal carries a reason the person can act on.
    private func perform(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let response = try await api.send(method: method, path: path, body: body)
        if [400, 404, 409, 422].contains(response.status) {
            throw HubRejection(status: response.status, detail: HubRejection.detail(in: response.body))
        }
        if let failure = LANTransport.map(status: response.status) { throw failure }
        return response.body
    }
}

/// The hub refused a request and said why (400, 404, 409 or 422).
struct HubRejection: Error, Equatable, LocalizedError {
    let status: Int
    let detail: String?

    var errorDescription: String? {
        if let detail, !detail.isEmpty { return detail }
        switch status {
        case 404: return "The hub does not have that item."
        case 409: return "The hub cannot do that in the current state."
        default: return "The hub refused this request."
        }
    }

    /// The `detail` text of a hub error body. A list of validation errors
    /// gives the first message.
    static func detail(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = object["detail"] else { return nil }
        if let text = detail as? String { return String(text.prefix(300)) }
        if let list = detail as? [[String: Any]], let message = list.first?["msg"] as? String {
            return String(message.prefix(300))
        }
        return nil
    }
}
