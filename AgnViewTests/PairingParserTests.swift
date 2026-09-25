import XCTest
@testable import AgnView

final class PairingParserTests: XCTestCase {
    // Fixtures are generated here. Every value is obviously fake.
    private let keyBytes = Data(repeating: 0x41, count: 32)
    private let idBytes = Data(repeating: 0x42, count: 16)
    private var keyText: String { Base64URL.encode(keyBytes) }
    private var idText: String { Base64URL.encode(idBytes) }
    private let fp = String(repeating: "a", count: 64)

    private func fields(version: Int = 1) -> [(String, String)] {
        [("v", String(version)), ("name", "Test Hub"), ("lan", "192.0.2.10:18845"),
         ("fp", fp), ("id", idText), ("k", keyText)]
    }

    private func ip(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> String {
        [a, b, c, d].map(String.init).joined(separator: ".")
    }

    private func makeURL(_ items: [(String, String)], scheme: String = "agnview", host: String = "pair") -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    private func replacing(_ name: String, with value: String, in items: [(String, String)]) -> [(String, String)] {
        items.map { $0.0 == name ? (name, value) : $0 }
    }

    private func removing(_ name: String, from items: [(String, String)]) -> [(String, String)] {
        items.filter { $0.0 != name }
    }

    private func assertThrows(_ url: URL, _ expected: PairingError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PairingParser.parse(url), file: file, line: line) { error in
            XCTAssertEqual(error as? PairingError, expected, file: file, line: line)
            XCTAssertFalse(String(describing: error).contains(self.keyText), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(self.keyText), file: file, line: line)
        }
    }

    func testV1HappyPath() throws {
        let p = try PairingParser.parse(makeURL(fields()))
        XCTAssertEqual(p.version, 1)
        XCTAssertEqual(p.name, "Test Hub")
        XCTAssertEqual(p.lanHost, "192.0.2.10")
        XCTAssertEqual(p.lanPort, 18845)
        XCTAssertEqual(p.fingerprint, fp)
        XCTAssertEqual(p.hubId, idBytes)
        XCTAssertEqual(p.key, keyBytes)
        XCTAssertNil(p.irohTicket)
        XCTAssertFalse(p.isLoopbackLAN)
        XCTAssertEqual(p.hubIdString, idText)
    }

    func testV2HappyPathWithTicket() throws {
        let items = fields(version: 2) + [("iroh", "endpointticketexample123")]
        let p = try PairingParser.parse(makeURL(items))
        XCTAssertEqual(p.version, 2)
        XCTAssertEqual(p.irohTicket, "endpointticketexample123")
    }

    func testV2WithoutTicketIsAccepted() throws {
        let p = try PairingParser.parse(makeURL(fields(version: 2)))
        XCTAssertNil(p.irohTicket)
    }

    func testParseFromText() throws {
        let text = makeURL(fields()).absoluteString
        XCTAssertEqual(try PairingParser.parse(text).name, "Test Hub")
        XCTAssertEqual(try PairingParser.parse("  \(text)\n").name, "Test Hub")
    }

    func testNameIsPercentDecoded() throws {
        let items = replacing("name", with: "Test Hub & Co", in: fields())
        XCTAssertEqual(try PairingParser.parse(makeURL(items)).name, "Test Hub & Co")
    }

    func testMissingEachRequiredField() {
        let expected: [String: PairingError] = [
            "v": .missingField("v"), "name": .missingField("name"), "lan": .missingField("lan"),
            "fp": .missingField("fp"), "id": .missingField("id"), "k": .missingField("k"),
        ]
        for (field, error) in expected {
            assertThrows(makeURL(removing(field, from: fields())), error)
        }
    }

    func testEmptyNameRejected() {
        assertThrows(makeURL(replacing("name", with: "", in: fields())), .missingField("name"))
    }

    func testBadBase64URL() {
        assertThrows(makeURL(replacing("k", with: "not base64 url!!", in: fields())), .invalidKey)
        assertThrows(makeURL(replacing("k", with: keyText.replacingOccurrences(of: "Q", with: "+"),
                                       in: fields())), .invalidKey)
        assertThrows(makeURL(replacing("id", with: "***", in: fields())), .invalidHubId)
    }

    func testWrongIdAndKeyLength() {
        let shortKey = Base64URL.encode(Data(repeating: 0x41, count: 31))
        let longKey = Base64URL.encode(Data(repeating: 0x41, count: 33))
        assertThrows(makeURL(replacing("k", with: shortKey, in: fields())), .invalidKey)
        assertThrows(makeURL(replacing("k", with: longKey, in: fields())), .invalidKey)
        let shortId = Base64URL.encode(Data(repeating: 0x42, count: 15))
        let longId = Base64URL.encode(Data(repeating: 0x42, count: 17))
        assertThrows(makeURL(replacing("id", with: shortId, in: fields())), .invalidHubId)
        assertThrows(makeURL(replacing("id", with: longId, in: fields())), .invalidHubId)
    }

    func testFingerprintRules() {
        assertThrows(makeURL(replacing("fp", with: String(repeating: "a", count: 63), in: fields())),
                     .invalidFingerprint)
        assertThrows(makeURL(replacing("fp", with: String(repeating: "a", count: 65), in: fields())),
                     .invalidFingerprint)
        assertThrows(makeURL(replacing("fp", with: String(repeating: "g", count: 64), in: fields())),
                     .invalidFingerprint)
    }

    func testBadLAN() {
        let bad = ["192.0.2.10", "192.0.2.10:0", "192.0.2.10:70000", "192.0.2.10:65536", "192.0.2.10:abc",
                   "192.0.2.10:", ":18845", "hub.example.test:18845", ip(8, 8, 8, 8) + ":18845",
                   ip(203, 0, 113, 5) + ":18845", ip(172, 32, 0, 1) + ":18845", "192.0.2.256:18845",
                   "192.0.2:18845", "192.0.2.10:1:2", ip(127, 0, 0, 2) + ":18845", "192.0.02.10:18845"]
        for lan in bad {
            assertThrows(makeURL(replacing("lan", with: lan, in: fields())), .invalidLAN)
        }
    }

    func testAllowedLANRanges() throws {
        for host in [ip(10, 1, 2, 3), ip(172, 16, 0, 1), ip(172, 31, 255, 254), "192.0.2.77", "127.0.0.1"] {
            let p = try PairingParser.parse(makeURL(replacing("lan", with: "\(host):1", in: fields())))
            XCTAssertEqual(p.lanHost, host)
            XCTAssertEqual(p.lanPort, 1)
        }
        let max = try PairingParser.parse(makeURL(replacing("lan", with: "192.0.2.10:65535", in: fields())))
        XCTAssertEqual(max.lanPort, 65535)
    }

    func testLoopbackFlag() throws {
        let p = try PairingParser.parse(makeURL(replacing("lan", with: "127.0.0.1:18845", in: fields())))
        XCTAssertTrue(p.isLoopbackLAN)
    }

    func testUnknownFieldsIgnored() throws {
        let items = fields() + [("future", "value"), ("x-extra", "1")]
        let p = try PairingParser.parse(makeURL(items))
        XCTAssertEqual(p.name, "Test Hub")
    }

    func testWrongSchemeAndHost() {
        assertThrows(makeURL(fields(), scheme: "https"), .wrongScheme)
        assertThrows(makeURL(fields(), host: "other"), .wrongHost)
    }

    func testUnsupportedVersions() {
        assertThrows(makeURL(fields(version: 3)), .unsupportedVersion)
        assertThrows(makeURL(fields(version: 0)), .unsupportedVersion)
        assertThrows(makeURL(replacing("v", with: "x", in: fields())), .unsupportedVersion)
    }

    func testIrohIgnoredOnV1() throws {
        let p = try PairingParser.parse(makeURL(fields() + [("iroh", "endpointticketexample123")]))
        XCTAssertEqual(p.version, 1)
        XCTAssertNil(p.irohTicket)
    }

    func testBadIrohTicketOnV2() {
        assertThrows(makeURL(fields(version: 2) + [("iroh", "")]), .invalidIrohTicket)
        assertThrows(makeURL(fields(version: 2) + [("iroh", "has space")]), .invalidIrohTicket)
    }

    func testGarbageText() {
        XCTAssertThrowsError(try PairingParser.parse("")) {
            XCTAssertEqual($0 as? PairingError, .malformedURL)
        }
        XCTAssertThrowsError(try PairingParser.parse("hello world")) {
            XCTAssertEqual($0 as? PairingError, .malformedURL)
        }
    }

    func testErrorDescriptionsNeverContainKey() {
        let errors: [PairingError] = [.malformedURL, .wrongScheme, .wrongHost, .unsupportedVersion,
                                      .missingField("k"), .invalidName, .invalidLAN, .invalidFingerprint,
                                      .invalidHubId, .invalidKey, .invalidIrohTicket]
        for error in errors {
            XCTAssertFalse(String(describing: error).contains(keyText))
            XCTAssertFalse(error.userMessage.contains(keyText))
            XCTAssertFalse(error.code.isEmpty)
        }
    }

    func testURLHandler() throws {
        let handler = PairingURLHandler()
        switch handler.handle(makeURL(fields())) {
        case .success(let p): XCTAssertEqual(p.name, "Test Hub")
        case .failure: XCTFail("expected success")
        }
        switch handler.handle(makeURL(fields(), host: "other")) {
        case .success: XCTFail("expected failure")
        case .failure(let e): XCTAssertEqual(e, .wrongHost)
        }
    }

    func testBase64URLRoundTrip() {
        for length in [1, 2, 3, 16, 32, 33] {
            let data = Data((0..<length).map { UInt8($0 & 0xFF) })
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
        }
        XCTAssertNil(Base64URL.decode(""))
        XCTAssertNil(Base64URL.decode("A"))
    }
}
