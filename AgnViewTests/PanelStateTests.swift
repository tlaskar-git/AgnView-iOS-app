import XCTest
@testable import AgnView

final class PanelStateTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    func testValueAndFailureAccessors() {
        XCTAssertNil(PanelState<Int>.loading.value)
        XCTAssertEqual(PanelState<Int>.loaded(3).value, 3)
        XCTAssertEqual(PanelState<Int>.stale(4, since: since).value, 4)
        XCTAssertNil(PanelState<Int>.failed("x").value)
        XCTAssertEqual(PanelState<Int>.failed("x").failureMessage, "x")
        XCTAssertNil(PanelState<Int>.loaded(1).failureMessage)
        XCTAssertTrue(PanelState<Int>.loading.isLoading)
    }

    func testLoadedBecomesStaleAndOtherStatesStay() {
        XCTAssertEqual(PanelState<Int>.loaded(5).markedStale(since: since), .stale(5, since: since))
        XCTAssertEqual(PanelState<Int>.loading.markedStale(since: since), .loading)
        XCTAssertEqual(PanelState<Int>.failed("x").markedStale(since: since), .failed("x"))
    }

    func testRetryTurnsAFailureIntoLoadingOnly() {
        XCTAssertEqual(PanelState<Int>.failed("x").retrying(), .loading)
        XCTAssertEqual(PanelState<Int>.loaded(1).retrying(), .loaded(1))
        XCTAssertEqual(PanelState<Int>.stale(1, since: since).retrying(), .stale(1, since: since))
    }

    func testFailureMessageNamesThePanel() {
        XCTAssertEqual(PanelState<Int>.failure(panel: "Usage"), .failed("Usage could not be read. Tap Retry."))
    }

    func testUnmeasuredUsageFiguresStayUnmeasured() throws {
        let json = #"[{"id":"a","provider":"claude","tokens_used":null,"cost_used_usd":null,"requests_used":null,"status":"unavailable","error_message":"No session"}]"#
        let accounts = try UsageAccount.decodeList(from: Data(json.utf8))
        let account = try XCTUnwrap(accounts.first)
        XCTAssertFalse(account.hasTokens)
        XCTAssertFalse(account.hasCost)
        XCTAssertFalse(account.hasRequests)
        XCTAssertEqual(account.errorMessage, "No session")
        let measured = try UsageAccount.decodeList(from: Data(#"[{"id":"b","provider":"claude","tokens_used":0}]"#.utf8))
        XCTAssertTrue(try XCTUnwrap(measured.first).hasTokens)
    }

    func testReplyTextShowsStatusAgentSessionAndMessage() {
        let response = DispatchResponse(status: "dispatched", agent: "codex", sessionId: "abcdef123456", message: "Accepted.")
        XCTAssertEqual(ConsoleComposer.replyText(response, fallbackAgent: "claude_code"),
                       "Status: dispatched\nAgent: Codex\nSession: abcdef12\nAccepted.")
        XCTAssertEqual(ConsoleComposer.replyText(DispatchResponse(), fallbackAgent: "claude_code"),
                       "Agent: Claude Code")
    }
}
