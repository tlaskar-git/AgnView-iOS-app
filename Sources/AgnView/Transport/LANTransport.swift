import Foundation

/// Full HTTP access to the hub on the local network.
///
/// Every request carries `X-AgnView-Token` with the token string the hub
/// compares: base64url of the pairing key, no padding.
final class LANTransport: Transport {
    static let tokenHeader = "X-AgnView-Token"

    let baseURL: URL?
    let token: String
    let session: URLSession
    let requestTimeout: TimeInterval

    init(baseURL: URL?, token: String, session: URLSession = .shared, requestTimeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.requestTimeout = requestTimeout
    }

    convenience init(endpoint: HubEndpoint, session: URLSession = .shared) {
        self.init(baseURL: LANTransport.baseURL(host: endpoint.lanHost, port: endpoint.lanPort),
                  token: endpoint.token, session: session)
    }

    static func baseURL(host: String, port: Int) -> URL? {
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        var hostPart = host
        if host.contains(":") && !host.hasPrefix("[") {
            hostPart = "[\(host)]"
        }
        return URL(string: "http://\(hostPart):\(port)")
    }

    /// Maps an HTTP status to a transport error. Nil means success.
    static func map(status: Int) -> TransportError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorised
        case 429: return .rateLimited
        default: return .protocolViolation
        }
    }

    func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                     body: Data? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TransportError.unreachable
        }
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw TransportError.unreachable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? requestTimeout
        request.setValue(token, forHTTPHeaderField: LANTransport.tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw TransportError.normalise(error)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw TransportError.protocolViolation }
        if let failure = LANTransport.map(status: http.statusCode) { throw failure }
        return data
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await send(makeRequest(path, query: query))
    }

    func post(_ path: String, json: Data) async throws -> Data {
        try await send(makeRequest(path, method: "POST", body: json))
    }

    /// GET /api/mobile/status. The ladder races this against 800 ms.
    func status() async throws -> Data {
        try await get("/api/mobile/status")
    }

    func connect() async throws -> HubSession {
        _ = try await status()
        return LANSession(transport: self)
    }

    /// Follows GET /api/events. The stream ends when the hub closes it.
    func events() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.makeRequest("/api/events", timeout: 60)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw TransportError.protocolViolation }
                    if let failure = LANTransport.map(status: http.statusCode) { throw failure }
                    var decoder = SSEDecoder()
                    var chunk = Data()
                    chunk.reserveCapacity(4096)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4096 {
                            for event in try decoder.feed(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        for event in try decoder.feed(chunk) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: TransportError.normalise(error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// LAN session: every capability. The console stream backfills from
/// /api/console/logs, then follows /api/events and fetches newer rows when an
/// event arrives. SSE ping events become ping frames.
final class LANSession: HubSession {
    let transport: LANTransport
    let route: TransportRoute = .lan
    let capabilities: Set<Capability> = .lan
    let backlog: Int

    private let lock = NSLock()
    private var pumpTask: Task<Void, Never>?
    private let stream: AsyncThrowingStream<ConsoleFrame, Error>
    private let continuation: AsyncThrowingStream<ConsoleFrame, Error>.Continuation

    init(transport: LANTransport, backlog: Int = 200) {
        self.transport = transport
        self.backlog = backlog
        var captured: AsyncThrowingStream<ConsoleFrame, Error>.Continuation!
        self.stream = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(10_000)) { captured = $0 }
        self.continuation = captured
    }

    /// The pump starts on first access, so a session the ladder drops never
    /// opens the event stream.
    var frames: AsyncThrowingStream<ConsoleFrame, Error> {
        lock.withLock {
            if pumpTask == nil {
                let task = Task { [weak self] in await self?.pump() }
                pumpTask = task
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return stream
    }

    private func pump() async {
        continuation.yield(.hello(ConsoleFrame.Hello(app: "AgnView", protocolVersion: 1,
                                                     hostname: nil, transport: "lan")))
        var afterId: Int?
        do {
            afterId = try await fetchLogs(after: nil, limit: backlog)
            for try await event in transport.events() {
                switch event.type {
                case "ping":
                    continuation.yield(.ping(transport: "lan"))
                case "connected":
                    continue
                default:
                    afterId = try await fetchLogs(after: afterId, limit: 500) ?? afterId
                }
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: TransportError.normalise(error))
            }
        }
    }

    /// Yields log frames newer than `after`. Returns the highest id seen.
    private func fetchLogs(after: Int?, limit: Int) async throws -> Int? {
        var query = [URLQueryItem(name: "agent", value: "all"),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let after { query.append(URLQueryItem(name: "after_id", value: String(after))) }
        let data = try await transport.get("/api/console/logs", query: query)
        let rows: [ConsoleFrame.LogEntry]
        do {
            rows = try JSONDecoder().decode([ConsoleFrame.LogEntry].self, from: data)
        } catch {
            throw TransportError.protocolViolation
        }
        var highest = after
        for row in rows.sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
            if let id = row.id, let seen = after, id <= seen { continue }
            if let id = row.id { highest = max(highest ?? id, id) }
            continuation.yield(.log(row))
        }
        return highest
    }

    func close() async {
        let task = lock.withLock { pumpTask }
        task?.cancel()
        continuation.finish()
    }
}
