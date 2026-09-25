import XCTest
@testable import AgnView

// MARK: - Test doubles shared by the transport and ladder tests

struct FakeEndpoint: HubEndpoint {
    var lanHost = "192.0.2.10"
    var lanPort = 8765
    var key = Data(repeating: 0xAB, count: 32)
    var irohTicket: String? = "endpointexampleticketnotreal"
    var isLoopbackLAN = false
}

final class FakeSession: HubSession {
    let route: TransportRoute
    let capabilities: Set<Capability>
    let frames: AsyncThrowingStream<ConsoleFrame, Error>
    private let lock = NSLock()
    private var closedFlag = false

    init(route: TransportRoute, capabilities: Set<Capability>? = nil) {
        self.route = route
        self.capabilities = capabilities ?? (route == .lan ? .lan : .iroh)
        self.frames = AsyncThrowingStream { $0.finish() }
    }

    var isClosed: Bool { lock.withLock { closedFlag } }

    func close() async {
        lock.withLock { closedFlag = true }
    }
}

final class FakeTransport: Transport {
    private let behaviour: () async throws -> HubSession
    private let lock = NSLock()
    private var count = 0

    init(_ behaviour: @escaping () async throws -> HubSession) {
        self.behaviour = behaviour
    }

    var connectCount: Int { lock.withLock { count } }

    func connect() async throws -> HubSession {
        lock.withLock { count += 1 }
        return try await behaviour()
    }

    static func session(_ route: TransportRoute) -> FakeTransport {
        FakeTransport { FakeSession(route: route) }
    }

    static func failing(_ error: TransportError) -> FakeTransport {
        FakeTransport { throw error }
    }

    /// Never answers until cancelled.
    static func hanging() -> FakeTransport {
        FakeTransport {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw TransportError.timedOut
        }
    }
}

/// Serves scripted chunks, then end of stream.
final class ScriptedReader {
    private let lock = NSLock()
    private var chunks: [Data]

    init(_ chunks: [String]) {
        self.chunks = chunks.map { Data($0.utf8) }
    }

    func read() async throws -> Data? {
        lock.withLock { chunks.isEmpty ? nil : chunks.removeFirst() }
    }
}

/// An iroh-shaped transport over scripted NDJSON chunks.
final class ScriptedStreamTransport: Transport {
    let chunks: [String]
    init(_ chunks: [String]) { self.chunks = chunks }

    func connect() async throws -> HubSession {
        let reader = ScriptedReader(chunks)
        return try await ConsoleStreamSession.open(read: { try await reader.read() }, onClose: {})
    }
}

func collect(_ stream: AsyncThrowingStream<ConsoleFrame, Error>) async -> (frames: [ConsoleFrame], error: Error?) {
    var frames: [ConsoleFrame] = []
    do {
        for try await frame in stream { frames.append(frame) }
        return (frames, nil)
    } catch {
        return (frames, error)
    }
}

// MARK: - Tests

final class TransportTests: XCTestCase {
    private let helloDirect = #"{"type":"hello","app":"AgnView","protocol":1,"hostname":"example-host","transport":"iroh-direct"}"# + "\n"
    private let helloRelay = #"{"type":"hello","app":"AgnView","protocol":1,"hostname":"example-host","transport":"iroh-relay"}"# + "\n"
    private let logLine = #"{"type":"log","id":1,"agent":"system","source":"system_notice","content":"Example","timestamp":"2026-01-01T00:00:00Z","session_id":null}"# + "\n"

    func testTokenIsBase64URLWithoutPadding() {
        XCTAssertEqual(HubToken.encode(Data([0xFB, 0xFF, 0xFE])), "-__-")
        XCTAssertEqual(HubToken.encode(Data([0x01])), "AQ")
        XCTAssertEqual(FakeEndpoint().token.count, 43)
        XCTAssertFalse(FakeEndpoint().token.contains("="))
    }

    func testCapabilities() {
        XCTAssertEqual(Set<Capability>.lan, [.consoleStream, .dispatch, .usage, .jobs, .sessions])
        XCTAssertEqual(Set<Capability>.iroh, [.consoleStream])
    }

    func testLANStatusMapping() {
        XCTAssertNil(LANTransport.map(status: 200))
        XCTAssertEqual(LANTransport.map(status: 401), .unauthorised)
        XCTAssertEqual(LANTransport.map(status: 429), .rateLimited)
        XCTAssertEqual(LANTransport.map(status: 500), .protocolViolation)
    }

    func testLANBaseURL() {
        XCTAssertEqual(LANTransport.baseURL(host: "192.0.2.10", port: 8765)?.absoluteString, "http://192.0.2.10:8765")
        XCTAssertEqual(LANTransport.baseURL(host: "2001:db8::1", port: 80)?.absoluteString, "http://[2001:db8::1]:80")
        XCTAssertNil(LANTransport.baseURL(host: "", port: 80))
        XCTAssertNil(LANTransport.baseURL(host: "192.0.2.10", port: 0))
    }

    func testLANRequestCarriesTokenHeader() throws {
        let transport = LANTransport(baseURL: URL(string: "http://192.0.2.10:8765"), token: "test-key-not-real")
        let request = try transport.makeRequest("/api/console/logs", query: [URLQueryItem(name: "limit", value: "5")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AgnView-Token"), "test-key-not-real")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Pairing-Key"))
        XCTAssertEqual(request.url?.absoluteString, "http://192.0.2.10:8765/api/console/logs?limit=5")
    }

    func testErrorNormalise() {
        XCTAssertEqual(TransportError.normalise(TransportError.rateLimited), .rateLimited)
        XCTAssertEqual(TransportError.normalise(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(TransportError.normalise(URLError(.cannotConnectToHost)), .unreachable)
    }

    func testStreamRouteDirectFromHello() async throws {
        let session = try await ScriptedStreamTransport([helloDirect, logLine]).connect()
        XCTAssertEqual(session.route, .direct)
        XCTAssertEqual(session.capabilities, [.consoleStream])
        let result = await collect(session.frames)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.frames.count, 2)
        guard case .hello(let hello) = result.frames[0] else { return XCTFail("hello first") }
        XCTAssertEqual(hello.hostname, "example-host")
        guard case .log(let entry) = result.frames[1] else { return XCTFail("log second") }
        XCTAssertEqual(entry.id, 1)
    }

    func testStreamRouteRelayFromHello() async throws {
        let session = try await ScriptedStreamTransport([helloRelay]).connect()
        XCTAssertEqual(session.route, .relay)
    }

    func testHelloSplitAcrossChunks() async throws {
        let half = helloDirect.count / 2
        let first = String(helloDirect.prefix(half))
        let second = String(helloDirect.dropFirst(half))
        let session = try await ScriptedStreamTransport([first, second + logLine]).connect()
        XCTAssertEqual(session.route, .direct)
        let result = await collect(session.frames)
        XCTAssertEqual(result.frames.count, 2)
    }

    func testPingUpdatesRoute() async throws {
        let ping = #"{"type":"ping","transport":"iroh-relay"}"# + "\n"
        let session = try await ScriptedStreamTransport([helloDirect, ping]).connect()
        XCTAssertEqual(session.route, .direct)
        let result = await collect(session.frames)
        XCTAssertEqual(result.frames.last, .ping(transport: "iroh-relay"))
        XCTAssertEqual(session.route, .relay)
    }

    func testAuthErrorBeforeHelloIsUnauthorised() async {
        let error = #"{"type":"error","detail":"unauthorised"}"# + "\n"
        do {
            _ = try await ScriptedStreamTransport([error]).connect()
            XCTFail("expected unauthorised")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorised)
        }
    }

    func testMalformedErrorBeforeHello() async {
        let error = #"{"type":"error","detail":"malformed request"}"# + "\n"
        do {
            _ = try await ScriptedStreamTransport([error]).connect()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
    }

    func testEndOfStreamBeforeHello() async {
        do {
            _ = try await ScriptedStreamTransport([]).connect()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
    }

    func testErrorFrameAfterHelloEndsStream() async throws {
        let error = #"{"type":"error","detail":"unauthorised"}"# + "\n"
        let session = try await ScriptedStreamTransport([helloDirect, logLine, error, logLine]).connect()
        let result = await collect(session.frames)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.error as? TransportError, .unauthorised)
    }

    func testUnknownFramesSkippedInStream() async throws {
        let future = #"{"type":"future","x":1}"# + "\n"
        let session = try await ScriptedStreamTransport([future, helloDirect, future, logLine]).connect()
        let result = await collect(session.frames)
        XCTAssertEqual(result.frames.count, 2)
    }

    func testIrohStubWhenNotLinked() async throws {
        guard !IrohSupport.isLinked else {
            throw XCTSkip("iroh is linked in this build")
        }
        do {
            _ = try await IrohTransport(ticket: "endpointexampleticketnotreal", token: nil).connect()
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? TransportError, .unavailable)
        }
    }

    func testIrohRejectsUnreadableTicket() async throws {
        guard IrohSupport.isLinked else {
            throw XCTSkip("iroh is not linked in this build")
        }
        do {
            _ = try await IrohTransport(ticket: "not-a-ticket", token: nil).connect()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
    }

    // MARK: Mock hub (CI starts it on 127.0.0.1:18081)

    private func mockHub(token: String = "test-key-not-real") -> LANTransport {
        let base = ProcessInfo.processInfo.environment["AGNVIEW_MOCK_HUB_URL"] ?? "http://127.0.0.1:18081"
        return LANTransport(baseURL: URL(string: base), token: token)
    }

    private func requireMockHub() async throws {
        do {
            _ = try await mockHub().status()
        } catch TransportError.unreachable {
            throw XCTSkip("mock hub is not running")
        }
    }

    func testMockHubStatusWithToken() async throws {
        try await requireMockHub()
        let data = try await mockHub().status()
        let status = try MobileStatus.decode(from: data)
        XCTAssertEqual(status.status, "healthy")
    }

    func testMockHubRejectsWrongToken() async throws {
        try await requireMockHub()
        do {
            _ = try await mockHub(token: "wrong-test-value").status()
            XCTFail("expected unauthorised")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorised)
        }
    }

    func testMockHubDispatch() async throws {
        try await requireMockHub()
        let body = Data(#"{"target_agent":"claude_code","prompt":"Example prompt"}"#.utf8)
        let data = try await mockHub().post("/api/console/dispatch", json: body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "dispatched")
    }

    func testMockHubEvents() async throws {
        try await requireMockHub()
        var types: [String] = []
        for try await event in mockHub().events() {
            types.append(event.type)
            if types.count == 2 { break }
        }
        XCTAssertEqual(types.first, "connected")
    }

    func testMockHubLANSessionFrames() async throws {
        try await requireMockHub()
        let session = try await mockHub().connect()
        XCTAssertEqual(session.route, .lan)
        var frames: [ConsoleFrame] = []
        for try await frame in session.frames {
            frames.append(frame)
            if frames.count == 4 { break }
        }
        await session.close()
        guard case .hello(let hello) = frames.first else { return XCTFail("hello first") }
        XCTAssertEqual(hello.transport, "lan")
        XCTAssertEqual(frames.dropFirst().filter { if case .log = $0 { return true } else { return false } }.count, 3)
    }
}
