import Foundation
import XCTest
@testable import AgnView

/// A request the stub saw.
struct RecordedRequest {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

/// URLProtocol stub for HubClient tests. Set `handler` to answer requests.
final class StubURLProtocol: URLProtocol {
    enum Answer {
        case response(Int, Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    private static var storedHandler: ((RecordedRequest) -> Answer)?
    private static var storedRequests: [RecordedRequest] = []

    static var handler: ((RecordedRequest) -> Answer)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    static var requests: [RecordedRequest] {
        lock.withLock { storedRequests }
    }

    static func reset() {
        lock.withLock {
            storedHandler = nil
            storedRequests = []
        }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let recorded = RecordedRequest(url: request.url ?? URL(fileURLWithPath: "/"),
                                       method: request.httpMethod ?? "GET",
                                       headers: request.allHTTPHeaderFields ?? [:],
                                       body: body)
        StubURLProtocol.lock.withLock { StubURLProtocol.storedRequests.append(recorded) }
        let answer = StubURLProtocol.handler?(recorded) ?? .response(404, Data())
        switch answer {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let data):
            let response = HTTPURLResponse(url: recorded.url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A session the test drives by hand.
final class ScriptedSession: HubSession {
    let route: TransportRoute
    let capabilities: Set<Capability>
    let frames: AsyncThrowingStream<ConsoleFrame, Error>
    private let continuation: AsyncThrowingStream<ConsoleFrame, Error>.Continuation

    init(route: TransportRoute, capabilities: Set<Capability>? = nil) {
        self.route = route
        self.capabilities = capabilities ?? (route == .lan ? .lan : .iroh)
        var captured: AsyncThrowingStream<ConsoleFrame, Error>.Continuation!
        self.frames = AsyncThrowingStream { captured = $0 }
        self.continuation = captured
    }

    func send(_ frame: ConsoleFrame) {
        continuation.yield(frame)
    }

    func sendLog(id: Int?, agent: String = "claude_code", content: String = "line",
                 sessionId: String? = nil, timestamp: String? = nil) {
        send(.log(ConsoleFrame.LogEntry(id: id, agent: agent, source: "stdout", content: content,
                                        timestamp: timestamp, sessionId: sessionId)))
    }

    /// Ends the stream. A non-nil error ends it with that error.
    func finish(_ error: Error? = nil) {
        continuation.finish(throwing: error)
    }

    func close() async {
        continuation.finish()
    }
}

/// Hands out one behaviour per connect. The last behaviour repeats.
final class TransportScript {
    typealias Behaviour = () async throws -> HubSession

    private let lock = NSLock()
    private var items: [Behaviour]

    init(_ items: [Behaviour]) {
        self.items = items
    }

    func next() -> Behaviour {
        lock.withLock { items.count > 1 ? items.removeFirst() : items[0] }
    }

    func transport() -> FakeTransport {
        FakeTransport { [self] in try await next()() }
    }

    static func session(_ session: ScriptedSession) -> Behaviour { { session } }
    static func fail(_ error: TransportError) -> Behaviour { { throw error } }
    static func fresh(_ route: TransportRoute) -> Behaviour { { ScriptedSession(route: route) } }
}

/// Thread-safe list for values the model passes to closures.
final class LockedList<T> {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) { lock.withLock { items.append(item) } }
    var values: [T] { lock.withLock { items } }
}

final class DateBox {
    private let lock = NSLock()
    private var stored: Date

    init(_ date: Date) { stored = date }

    var date: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

enum SampleJSON {
    static let status = #"{"status":"healthy","service":"Example Hub","version":"0.0.0-test","paired_agents_online":1}"#

    static let usage = """
    [{"id":"acc-1","name":"Example Claude","provider":"claude","plan_name":"Example plan",
      "tokens_used":1200,"tokens_limit":10000,"cost_used":1.5,"cost_limit":null,
      "requests_count":7,"last_probed":"2026-01-01T00:00:00Z","is_active":true},
     {"id":"acc-2","name":"Example Gemini","provider":"gemini","plan_name":"Example plan",
      "tokens_used":30,"tokens_limit":null,"cost_used":0,"cost_limit":null,
      "requests_count":1,"last_probed":null,"is_active":false}]
    """

    static let jobs = """
    [{"id":"job-1","title":"Example pipeline","description":"Placeholder job","status":"in_progress",
      "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
      "tasks":[{"id":"task-1","job_id":"job-1","title":"Example task","description":"Placeholder",
                "assigned_agent":"example-agent","status":"ready","dependencies":["task-0"],
                "output_summary":null}]}]
    """

    static let liveSessions = """
    [{"agent":"claude_code","session_id":"session-1","working_directory":"example-project",
      "busy":true,"idle_seconds":12.5}]
    """

    static let dispatch = #"{"status":"dispatched","agent":"claude_code","session_id":"sess-1","message":"Accepted."}"#
}
