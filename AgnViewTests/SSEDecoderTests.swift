import XCTest
@testable import AgnView

final class SSEDecoderTests: XCTestCase {
    func testNamedEvent() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(Data("event: connected\ndata: {\"status\":\"connected\"}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(type: "connected", data: "{\"status\":\"connected\"}", id: nil)])
    }

    func testDefaultTypeIsMessage() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(Data("data: hello\n\n".utf8))
        XCTAssertEqual(events.first?.type, "message")
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testMultipleDataLinesJoinWithNewline() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(Data("data: one\ndata: two\n\n".utf8))
        XCTAssertEqual(events.first?.data, "one\ntwo")
    }

    func testCommentsAndKeepAliveAreIgnored() throws {
        var decoder = SSEDecoder()
        XCTAssertEqual(try decoder.feed(Data(": keep-alive\n\n".utf8)), [])
        let events = try decoder.feed(Data(":x\nevent: ping\ndata: {}\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(type: "ping", data: "{}", id: nil)])
    }

    func testChunksSplitAnywhere() throws {
        var decoder = SSEDecoder()
        let body = "event: job_created\ndata: {\"id\":\"job-1\"}\n\nevent: ping\ndata: {}\n\n"
        var events: [SSEEvent] = []
        for byte in Data(body.utf8) {
            events += try decoder.feed(Data([byte]))
        }
        XCTAssertEqual(events.map(\.type), ["job_created", "ping"])
        XCTAssertEqual(events.first?.data, "{\"id\":\"job-1\"}")
    }

    func testCRLFLineEndings() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(Data("event: ping\r\ndata: {}\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(type: "ping", data: "{}", id: nil)])
    }

    func testIdIsKept() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(Data("id: 7\ndata: x\n\n".utf8))
        XCTAssertEqual(events.first?.id, "7")
    }

    func testNoSpaceAfterColon() {
        var decoder = SSEDecoder()
        XCTAssertNil(decoder.feed(line: "event:ping"))
        XCTAssertNil(decoder.feed(line: "data:{}"))
        XCTAssertEqual(decoder.feed(line: ""), SSEEvent(type: "ping", data: "{}", id: nil))
    }

    func testOversizedLineThrows() {
        var decoder = SSEDecoder(maxLineLength: 4)
        XCTAssertThrowsError(try decoder.feed(Data("data: too long".utf8))) { error in
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
    }
}
