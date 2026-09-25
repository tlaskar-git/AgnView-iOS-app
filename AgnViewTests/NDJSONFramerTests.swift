import XCTest
@testable import AgnView

final class NDJSONFramerTests: XCTestCase {
    private func text(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testCompleteLinesInOneChunk() throws {
        var framer = NDJSONFramer()
        let lines = try framer.feed(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(text(lines), ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testChunkSplitMidLine() throws {
        var framer = NDJSONFramer()
        XCTAssertEqual(try framer.feed(Data("{\"type\":\"pi".utf8)), [])
        XCTAssertEqual(framer.pendingByteCount, 11)
        XCTAssertEqual(try framer.feed(Data("ng\"}".utf8)), [])
        let lines = try framer.feed(Data("\n{\"type\"".utf8))
        XCTAssertEqual(text(lines), ["{\"type\":\"ping\"}"])
        XCTAssertEqual(text(try framer.feed(Data(":\"log\"}\n".utf8))), ["{\"type\":\"log\"}"])
    }

    func testByteAtATime() throws {
        var framer = NDJSONFramer()
        var out: [Data] = []
        for byte in Data("one\ntwo\n".utf8) {
            out += try framer.feed(Data([byte]))
        }
        XCTAssertEqual(text(out), ["one", "two"])
    }

    func testCRLFIsStripped() throws {
        var framer = NDJSONFramer()
        let lines = try framer.feed(Data("first\r\nsecond\r".utf8))
        XCTAssertEqual(text(lines), ["first"])
        XCTAssertEqual(text(try framer.feed(Data("\n".utf8))), ["second"])
    }

    func testEmptyLinesAreDropped() throws {
        var framer = NDJSONFramer()
        XCTAssertEqual(text(try framer.feed(Data("\n\r\nx\n\n".utf8))), ["x"])
    }

    func testOversizedLineThrows() {
        var framer = NDJSONFramer(maxLineLength: 8)
        XCTAssertThrowsError(try framer.feed(Data("0123456789".utf8))) { error in
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testLineAtLimitIsAccepted() throws {
        var framer = NDJSONFramer(maxLineLength: 8)
        XCTAssertEqual(text(try framer.feed(Data("01234567\n".utf8))), ["01234567"])
    }

    func testFinishReturnsTrailingLine() throws {
        var framer = NDJSONFramer()
        _ = try framer.feed(Data("tail".utf8))
        XCTAssertEqual(framer.finish().map { String(decoding: $0, as: UTF8.self) }, "tail")
        XCTAssertNil(framer.finish())
    }

    func testUnknownFrameTypesAreIgnored() throws {
        var framer = NDJSONFramer()
        let chunk = Data("""
        {"type":"future","x":1}
        not json
        {"type":"ping","transport":"iroh-relay"}

        """.utf8)
        let frames = try framer.feed(chunk).compactMap(ConsoleFrame.decode(line:))
        XCTAssertEqual(frames, [.ping(transport: "iroh-relay")])
    }
}
