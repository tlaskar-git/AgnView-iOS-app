import XCTest
@testable import AgnView

final class FormatTests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(Format.tokens(0), "0")
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(1000), "1K")
        XCTAssertEqual(Format.tokens(1500), "1.5K")
        XCTAssertEqual(Format.tokens(120_000), "120K")
        XCTAssertEqual(Format.tokens(999_950), "1M")
        XCTAssertEqual(Format.tokens(1_200_000), "1.2M")
        XCTAssertEqual(Format.tokens(-1500), "-1.5K")
    }

    func testCost() {
        XCTAssertEqual(Format.cost(0), "$0.00")
        XCTAssertEqual(Format.cost(12.5), "$12.50")
        XCTAssertEqual(Format.cost(100), "$100.00")
    }

    func testAge() {
        XCTAssertEqual(Format.age(seconds: -5), "just now")
        XCTAssertEqual(Format.age(seconds: 30), "just now")
        XCTAssertEqual(Format.age(seconds: 60), "1 min ago")
        XCTAssertEqual(Format.age(seconds: 300), "5 min ago")
        XCTAssertEqual(Format.age(seconds: 7200), "2 h ago")
        XCTAssertEqual(Format.age(seconds: 172_800), "2 d ago")
    }

    func testLastReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.lastReading(from: now.addingTimeInterval(-300), to: now),
                       "Last reading 5 min ago")
    }

    func testFraction() {
        XCTAssertNil(Format.fraction(used: 5, limit: nil))
        XCTAssertNil(Format.fraction(used: 5, limit: 0))
        XCTAssertEqual(Format.fraction(used: 25, limit: 100), 0.25)
        XCTAssertEqual(Format.fraction(used: 500, limit: 100), 1)
    }

    func testNames() {
        XCTAssertEqual(Format.agentName("claude_code"), "Claude Code")
        XCTAssertEqual(Format.providerName("chatgpt"), "ChatGPT")
        XCTAssertEqual(Format.shortId("abcdefghijkl"), "abcdefgh")
    }
}
