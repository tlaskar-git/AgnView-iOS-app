import XCTest
@testable import AgnView

/// A fake iroh stream. It records what the client writes and serves the
/// scripted reply. In hang mode a read waits until the client cancels.
final class FakeAPIStream {
    private let lock = NSLock()
    private var written = Data()
    private var finished = false
    private var cancelled = false
    private var replies: [Data]
    private let hang: Bool
    private let channel = ChannelReader()

    init(reply chunks: [String] = [], hang: Bool = false) {
        self.replies = chunks.map { Data($0.utf8) }
        self.hang = hang
    }

    var writtenData: Data { lock.withLock { written } }
    var didFinish: Bool { lock.withLock { finished } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    var io: APIStreamIO {
        APIStreamIO(
            write: { [self] data in lock.withLock { written.append(data) } },
            finish: { [self] in lock.withLock { finished = true } },
            read: { [self] in
                if hang { return await channel.read() }
                return lock.withLock { replies.isEmpty ? nil : replies.removeFirst() }
            },
            cancel: { [self] in
                lock.withLock { cancelled = true }
                channel.end()
            })
    }
}

final class APITransportTests: XCTestCase {
    private let hello = #"{"type":"hello","app":"AgnView","protocol":1,"transport":"iroh-direct","capabilities":["console","api"]}"# + "\n"

    private func transport(_ stream: FakeAPIStream, timeout: TimeInterval = 5) -> IrohAPITransport {
        IrohAPITransport(token: "test-key-not-real", timeout: timeout, openStream: { stream.io })
    }

    private func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.8")
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func assertFails(_ expected: TransportError, file: StaticString = #filePath, line: UInt = #line,
                             _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TransportError, expected, file: file, line: line)
        }
    }

    // MARK: Request line

    func testRequestLineHasExactKeysAndOneNewline() throws {
        let body = Data(#"{"agent":"codex","prompt":"hi"}"#.utf8)
        let line = try IrohAPITransport.requestLine(token: "test-key-not-real", method: "POST",
                                                    path: "/api/console/dispatch", body: body)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["token", "op", "method", "path", "body"])
        XCTAssertEqual(object["token"] as? String, "test-key-not-real")
        XCTAssertEqual(object["op"] as? String, "api")
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["path"] as? String, "/api/console/dispatch")
        XCTAssertEqual((object["body"] as? [String: Any])?["agent"] as? String, "codex")
    }

    func testGetRequestCarriesNullBodyAndQueryStaysInPath() throws {
        let line = try IrohAPITransport.requestLine(token: "k", method: "GET",
                                                    path: "/api/console/logs?agent=all&limit=50", body: nil)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertTrue(object["body"] is NSNull)
        XCTAssertEqual(object["path"] as? String, "/api/console/logs?agent=all&limit=50")
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.contains("/api/console/logs?agent=all&limit=50"), "slashes are not escaped")
    }

    func testOversizedRequestIsRefusedBeforeSending() {
        let big = Data(("{\"prompt\":\"" + String(repeating: "a", count: 70_000) + "\"}").utf8)
        XCTAssertThrowsError(try IrohAPITransport.requestLine(token: "k", method: "POST", path: "/api/console/dispatch", body: big)) {
            XCTAssertEqual($0 as? TransportError, .protocolViolation)
        }
    }

    func testSendWritesTheLineFinishesAndSkipsHello() async throws {
        let stream = FakeAPIStream(reply: [hello, #"{"type":"response","status":200,"body":{"status":"healthy"}}"# + "\n"])
        let response = try await transport(stream).send(method: "GET", path: "/api/mobile/status", body: nil)
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "healthy")
        XCTAssertTrue(stream.didFinish)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: stream.writtenData.dropLast()) as? [String: Any])
        XCTAssertEqual(sent["path"] as? String, "/api/mobile/status")
    }

    func testFramesSplitAcrossChunksAreJoined() async throws {
        let frame = #"{"type":"response","status":200,"body":[1,2,3]}"#
        let cut = frame.index(frame.startIndex, offsetBy: 20)
        let stream = FakeAPIStream(reply: [hello, String(frame[..<cut]), String(frame[cut...]) + "\n"])
        let response = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "[1,2,3]")
    }

    // MARK: Response and error frames

    func testStringBodyIsEncodedAsJSONString() async throws {
        let stream = FakeAPIStream(reply: [hello, #"{"type":"response","status":502,"body":"upstream text"}"# + "\n"])
        let response = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
        XCTAssertEqual(response.status, 502)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "\"upstream text\"")
    }

    func testNullBodyGivesEmptyData() async throws {
        let stream = FakeAPIStream(reply: [hello, #"{"type":"response","status":204,"body":null}"# + "\n"])
        let response = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testErrorFramesMapToTransportErrors() async {
        let cases: [(String, TransportError)] = [
            ("unauthorised", .unauthorised), ("rate_limited", .rateLimited), ("timeout", .timedOut),
            ("forbidden_path", .notSupported), ("bad_request", .notSupported),
            ("too_large", .protocolViolation), ("upstream_error", .protocolViolation),
            ("something_new", .protocolViolation),
        ]
        for (detail, expected) in cases {
            let stream = FakeAPIStream(reply: [hello, #"{"type":"error","detail":"\#(detail)"}"# + "\n"])
            await assertFails(expected) {
                _ = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
            }
        }
    }

    func testErrorBeforeHelloForBadKey() async {
        let stream = FakeAPIStream(reply: [#"{"type":"error","detail":"unauthorised"}"# + "\n"])
        await assertFails(.unauthorised) {
            _ = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
        }
    }

    func testStreamEndingWithoutResponseIsProtocolViolation() async {
        let stream = FakeAPIStream(reply: [hello])
        await assertFails(.protocolViolation) {
            _ = try await transport(stream).send(method: "GET", path: "/api/jobs", body: nil)
        }
    }

    func testOpenFailureIsUnreachable() async {
        let api = IrohAPITransport(token: "k", openStream: { throw NSError(domain: "x", code: 1) })
        await assertFails(.unreachable) {
            _ = try await api.send(method: "GET", path: "/api/jobs", body: nil)
        }
    }

    // MARK: Timeout and cancellation

    func testTimeoutCancelsTheStream() async {
        let stream = FakeAPIStream(hang: true)
        await assertFails(.timedOut) {
            _ = try await transport(stream, timeout: 0.15).send(method: "GET", path: "/api/jobs", body: nil)
        }
        XCTAssertTrue(stream.wasCancelled)
    }

    func testCancellationCancelsTheStream() async throws {
        let stream = FakeAPIStream(hang: true)
        let api = transport(stream, timeout: 30)
        let task = Task { try await api.send(method: "GET", path: "/api/jobs", body: nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(stream.wasCancelled)
    }

    // MARK: Hello capabilities

    func testHelloWithApiGivesFullCapabilitiesAndAPIRoute() async throws {
        let reader = ChannelReader()
        reader.send(hello)
        let session = try await ConsoleStreamSession.open(
            makeAPI: { IrohAPITransport(token: "k", openStream: { FakeAPIStream().io }) },
            read: { await reader.read() }, onClose: {})
        XCTAssertEqual(session.capabilities, .irohAPI)
        XCTAssertNotNil(session.api)
        XCTAssertEqual(session.route, .direct)
        XCTAssertEqual(session.hello.capabilities, ["console", "api"])
        reader.end()
        await session.close()
    }

    func testHelloWithUploadsAddsPipelineCreateAndDelete() async throws {
        let reader = ChannelReader()
        reader.send(#"{"type":"hello","app":"AgnView","protocol":1,"transport":"iroh-relay","capabilities":["console","api","uploads"]}"# + "\n")
        let session = try await ConsoleStreamSession.open(
            makeAPI: { IrohAPITransport(token: "k", openStream: { FakeAPIStream().io }) },
            read: { await reader.read() }, onClose: {})
        XCTAssertEqual(session.capabilities, .irohJobs)
        XCTAssertTrue(session.capabilities.contains(.manageJobs))
        XCTAssertNotNil(session.api)
        XCTAssertEqual(session.route, .relay)
        reader.end()
        await session.close()
    }

    func testHelloWithoutCapabilitiesKeepsConsoleOnly() async throws {
        let reader = ChannelReader()
        reader.send(#"{"type":"hello","app":"AgnView","protocol":1,"transport":"iroh-relay"}"# + "\n")
        let session = try await ConsoleStreamSession.open(
            makeAPI: { IrohAPITransport(token: "k", openStream: { FakeAPIStream().io }) },
            read: { await reader.read() }, onClose: {})
        XCTAssertEqual(session.capabilities, [.consoleStream])
        XCTAssertNil(session.api)
        XCTAssertNil(session.hello.capabilities)
        reader.end()
        await session.close()
    }

    func testHelloWithConsoleOnlyCapabilityKeepsConsoleOnly() async throws {
        let reader = ChannelReader()
        reader.send(#"{"type":"hello","app":"AgnView","protocol":1,"transport":"iroh-relay","capabilities":["console"]}"# + "\n")
        let session = try await ConsoleStreamSession.open(
            makeAPI: { IrohAPITransport(token: "k", openStream: { FakeAPIStream().io }) },
            read: { await reader.read() }, onClose: {})
        XCTAssertEqual(session.capabilities, [.consoleStream])
        XCTAssertNil(session.api)
        reader.end()
        await session.close()
    }

    // MARK: HubClient over a fake API with the merged fixtures

    func testHubClientOverFakeAPIWithFixtures() async throws {
        let api = FakeAPITransport()
        func serve(_ method: String, _ path: String, _ name: String) throws {
            let text = String(decoding: try fixture(name), as: UTF8.self)
            api.route(method, path, 200, text)
        }
        try serve("GET", "/api/mobile/status", "status.json")
        try serve("GET", "/api/usage/accounts", "usage_accounts.json")
        try serve("GET", "/api/jobs", "jobs_fresh.json")
        try serve("GET", "/api/console/live-sessions", "live_sessions_from_source.json")
        try serve("POST", "/api/console/dispatch", "dispatch_response.json")
        let client = HubClient(api: api)
        let status = try await client.status()
        XCTAssertEqual(status.status, "healthy")
        let accounts = try await client.usageAccounts()
        let jobs = try await client.jobs()
        let live = try await client.liveSessions()
        XCTAssertFalse(accounts.isEmpty)
        XCTAssertFalse(jobs.isEmpty)
        XCTAssertFalse(live.isEmpty)
        let response = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: "p"))
        XCTAssertEqual(response.status, "dispatched")
        let post = try XCTUnwrap(api.calls.first { $0.method == "POST" })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(json["agent"] as? String, "codex")
    }

    func testHubClientMapsStatusesFromTheAPI() async {
        let api = FakeAPITransport()
        api.route("GET", "/api/jobs", 401, "{}")
        api.route("GET", "/api/mobile/status", 429, "{}")
        api.route("POST", "/api/console/dispatch", 422, #"{"detail":"unknown_agent"}"#)
        let client = HubClient(api: api)
        await assertFails(.unauthorised) { _ = try await client.jobs() }
        await assertFails(.rateLimited) { _ = try await client.status() }
        await assertFails(.protocolViolation) {
            _ = try await client.dispatch(DispatchRequest(targetAgent: "nope", prompt: "p"))
        }
    }

    func testHubErrorForNotSupportedShowsUpdateMessage() {
        XCTAssertEqual(HubError.transport(.notSupported).errorDescription, UserMessages.hubNeedsUpdate)
    }
}
