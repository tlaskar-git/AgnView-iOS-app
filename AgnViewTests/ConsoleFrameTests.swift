import XCTest
@testable import AgnView

final class ConsoleFrameTests: XCTestCase {
    private func decode(_ json: String) -> ConsoleFrame? {
        ConsoleFrame.decode(line: Data(json.utf8))
    }

    func testHello() {
        let frame = decode(#"{"type":"hello","app":"AgnView","protocol":1,"hostname":"example-host","transport":"iroh-direct"}"#)
        XCTAssertEqual(frame, .hello(ConsoleFrame.Hello(app: "AgnView", protocolVersion: 1,
                                                        hostname: "example-host", transport: "iroh-direct")))
        XCTAssertEqual(frame?.reportedRoute, .direct)
    }

    func testLog() {
        let frame = decode(#"{"type":"log","id":42,"agent":"claude_code","source":"stdout","content":"Example line","timestamp":"2026-01-01T00:00:00Z","session_id":null}"#)
        guard case .log(let entry)? = frame else { return XCTFail("expected a log frame") }
        XCTAssertEqual(entry.id, 42)
        XCTAssertEqual(entry.agent, "claude_code")
        XCTAssertEqual(entry.source, "stdout")
        XCTAssertEqual(entry.content, "Example line")
        XCTAssertNil(entry.sessionId)
    }

    func testLogIdAsString() {
        guard case .log(let entry)? = decode(#"{"type":"log","id":"7","content":"x"}"#) else {
            return XCTFail("expected a log frame")
        }
        XCTAssertEqual(entry.id, 7)
    }

    func testPing() {
        XCTAssertEqual(decode(#"{"type":"ping","transport":"iroh-relay"}"#), .ping(transport: "iroh-relay"))
        XCTAssertEqual(decode(#"{"type":"ping","transport":"iroh-relay"}"#)?.reportedRoute, .relay)
        XCTAssertEqual(decode(#"{"type":"ping"}"#), .ping(transport: nil))
    }

    func testError() {
        XCTAssertEqual(decode(#"{"type":"error","detail":"unauthorised"}"#), .error(detail: "unauthorised"))
        XCTAssertEqual(ConsoleFrame.mapError(detail: "unauthorised"), .unauthorised)
        XCTAssertEqual(ConsoleFrame.mapError(detail: "malformed request"), .protocolViolation)
    }

    func testUnknownAndMalformed() {
        XCTAssertNil(decode(#"{"type":"future"}"#))
        XCTAssertNil(decode(#"{"no_type":true}"#))
        XCTAssertNil(decode("not json"))
    }

    func testEncodeRoundTrip() throws {
        let frames: [ConsoleFrame] = [
            .hello(ConsoleFrame.Hello(app: "AgnView", protocolVersion: 1, hostname: nil, transport: "lan")),
            .log(ConsoleFrame.LogEntry(id: 1, agent: "system", source: "system_notice",
                                       content: "Example", timestamp: nil, sessionId: "session-1")),
            .ping(transport: "iroh-direct"),
            .error(detail: "unauthorised"),
        ]
        for frame in frames {
            let data = try JSONEncoder().encode(frame)
            XCTAssertEqual(ConsoleFrame.decode(line: data), frame)
        }
    }

    func testRouteMapping() {
        XCTAssertEqual(TransportRoute(hubValue: "lan"), .lan)
        XCTAssertEqual(TransportRoute(hubValue: "iroh-direct"), .direct)
        XCTAssertEqual(TransportRoute(hubValue: "iroh-relay"), .relay)
        XCTAssertNil(TransportRoute(hubValue: "offline"))
        XCTAssertNil(TransportRoute(hubValue: nil))
    }

    func testIrohRequestBody() throws {
        let body = IrohConsoleRequest.body(token: "test-key-not-real", agent: "all", backlog: 200, afterId: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "test-key-not-real")
        XCTAssertEqual(object["agent"] as? String, "all")
        XCTAssertEqual(object["backlog"] as? Int, 200)
        XCTAssertTrue(object["after_id"] is NSNull)

        let noToken = IrohConsoleRequest.body(token: nil, afterId: 12)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: noToken) as? [String: Any])
        XCTAssertTrue(second["token"] is NSNull)
        XCTAssertEqual(second["after_id"] as? Int, 12)
        XCTAssertEqual(IrohConsoleRequest.alpn, Data("agnview/console/1".utf8))
    }
}
