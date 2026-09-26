import Foundation

/// The hub API over HTTP on the local network.
struct LANAPITransport: APITransport {
    let lan: LANTransport

    func send(method: String, path: String, body: Data?) async throws -> APIResponse {
        var route = path
        var query: [URLQueryItem] = []
        if let mark = path.firstIndex(of: "?") {
            route = String(path[..<mark])
            var components = URLComponents()
            // The query in a path is already percent encoded.
            components.percentEncodedQuery = String(path[path.index(after: mark)...])
            query = components.queryItems ?? []
        }
        // The hub reads every provider again for a usage refresh, which takes
        // longer than an ordinary call.
        let timeout: TimeInterval? = route == HubPath.usageRefreshAll ? 60 : nil
        let request = try lan.makeRequest(route, method: method, query: query, body: body, timeout: timeout)
        let result: (Data, URLResponse)
        do {
            result = try await lan.session.data(for: request)
        } catch {
            throw TransportError.normalise(error)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw TransportError.protocolViolation }
        return APIResponse(status: http.statusCode, body: result.0)
    }
}

/// One bidirectional stream, as the iroh transport hands it out. The closures
/// let a test drive the exchange without a network.
struct APIStreamIO {
    var write: (Data) async throws -> Void
    var finish: () async throws -> Void
    var read: ChunkReader
    /// Abandons the stream. Must make a pending read return or throw.
    var cancel: () -> Void
}

/// The hub API over iroh. Each call opens its own stream on the session's
/// connection, writes one request line, finishes its send side and reads the
/// hello frame and then one response or error frame.
final class IrohAPITransport: APITransport {
    static let defaultTimeout: TimeInterval = 35
    /// The hub refuses a request line above this size.
    static let maxRequestBytes = 64 * 1024
    /// A response body is at most 1 MiB before JSON framing.
    static let maxFrameBytes = 8 * 1024 * 1024

    private let token: String
    private let timeout: TimeInterval
    private let openStream: () async throws -> APIStreamIO

    init(token: String, timeout: TimeInterval = IrohAPITransport.defaultTimeout,
         openStream: @escaping () async throws -> APIStreamIO) {
        self.token = token
        self.timeout = timeout
        self.openStream = openStream
    }

    /// `{"body": ..., "method": ..., "op": "api", "path": ..., "token": ...}`
    /// followed by a newline.
    static func requestLine(token: String, method: String, path: String, body: Data?) throws -> Data {
        var bodyValue: Any = NSNull()
        if let body, !body.isEmpty {
            guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
                throw TransportError.protocolViolation
            }
            bodyValue = value
        }
        let object: [String: Any] = [
            "token": token,
            "op": "api",
            "method": method,
            "path": path,
            "body": bodyValue,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw TransportError.protocolViolation
        }
        line.append(0x0A)
        guard line.count <= maxRequestBytes else { throw TransportError.protocolViolation }
        return line
    }

    /// Returns the response for a response frame, throws for an error frame and
    /// returns nil for a frame to skip (hello, unknown types).
    static func interpret(line: Data) throws -> APIResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "response":
            guard let status = object["status"] as? Int else { throw TransportError.protocolViolation }
            return APIResponse(status: status, body: try encodeBody(object["body"]))
        case "error":
            throw ConsoleFrame.mapError(detail: object["detail"] as? String ?? "")
        default:
            return nil
        }
    }

    private static func encodeBody(_ value: Any?) throws -> Data {
        guard let value, !(value is NSNull) else { return Data() }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            throw TransportError.protocolViolation
        }
        return data
    }

    func send(method: String, path: String, body: Data?) async throws -> APIResponse {
        let request = try Self.requestLine(token: token, method: method, path: path, body: body)
        let gate = CallGate()
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<APIResponse, Error>) in
                gate.install(continuation)
                let work = Task {
                    do {
                        gate.finish(.success(try await self.exchange(request, gate: gate)))
                    } catch {
                        gate.finish(.failure(TransportError.normalise(error)))
                    }
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    gate.finish(.failure(TransportError.timedOut))
                }
                gate.attach([work, timer])
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private func exchange(_ request: Data, gate: CallGate) async throws -> APIResponse {
        let io = try await openStream()
        gate.setCancel(io.cancel)
        try await io.write(request)
        try await io.finish()
        var framer = NDJSONFramer(maxLineLength: Self.maxFrameBytes)
        while true {
            guard let chunk = try await io.read(), !chunk.isEmpty else {
                if let last = framer.finish(), let response = try Self.interpret(line: last) {
                    return response
                }
                throw TransportError.protocolViolation
            }
            for line in try framer.feed(chunk) {
                if let response = try Self.interpret(line: line) { return response }
            }
        }
    }
}

/// Settles one call exactly once: by the answer, the timer or a cancellation.
/// Whichever comes first wins. A loser that is still reading is cancelled.
private final class CallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<APIResponse, Error>?
    private var settled: Result<APIResponse, Error>?
    private var resumed = false
    private var tasks: [Task<Void, Never>] = []
    private var cancelStream: (() -> Void)?

    func install(_ continuation: CheckedContinuation<APIResponse, Error>) {
        let early: Result<APIResponse, Error>? = lock.withLock {
            if let settled {
                resumed = true
                return settled
            }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let done = lock.withLock { () -> Bool in
            self.tasks = tasks
            return settled != nil
        }
        if done { tasks.forEach { $0.cancel() } }
    }

    func setCancel(_ cancel: @escaping () -> Void) {
        let done = lock.withLock { () -> Bool in
            cancelStream = cancel
            return settled != nil
        }
        if done { cancel() }
    }

    func finish(_ result: Result<APIResponse, Error>) {
        let (continuation, tasks, cancel, first) = lock.withLock {
            () -> (CheckedContinuation<APIResponse, Error>?, [Task<Void, Never>], (() -> Void)?, Bool) in
            if settled != nil { return (nil, [], nil, false) }
            settled = result
            let continuation = self.continuation
            self.continuation = nil
            if continuation != nil { resumed = true }
            return (continuation, self.tasks, self.cancelStream, true)
        }
        guard first else { return }
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
        if case .failure = result { cancel?() }
    }
}
