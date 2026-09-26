import XCTest
@testable import AgnView

/// The conversation built from console lines, the streaming rule, the
/// relative time text, the fixed agent order and the tab bar labels.
final class ChatTurnsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2 January 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_767_355_200)

    private func line(_ id: Int, _ agent: String, _ content: String,
                      session: String? = "s1", time: String? = "2026-01-02T09:41:00Z") -> ConsoleLine {
        ConsoleLine(id: id, agent: agent, source: "stdout", content: content,
                    timestamp: time, sessionId: session)
    }

    private func build(_ lines: [ConsoleLine]) -> [ChatItem] {
        var builder = ChatBuilder(calendar: calendar)
        builder.sync(lines, now: now)
        return builder.items
    }

    private func replies(_ items: [ChatItem]) -> [ChatReply] {
        items.compactMap { if case .agent(let reply) = $0 { return reply } else { return nil } }
    }

    // MARK: Grouping

    func testConsecutiveLinesOfOneAgentAreOneReply() {
        let items = build([line(1, "claude_code", "one"), line(2, "claude_code", "two"),
                           line(3, "claude_code", "three")])
        XCTAssertEqual(items.count, 2, "a time label and one reply")
        guard case .separator(_, let label) = items[0] else { return XCTFail("no time label first") }
        XCTAssertEqual(label, "Today, 09:41")
        let all = replies(items)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].text, "one\ntwo\nthree")
        XCTAssertEqual(all[0].blocks, [.text("one\ntwo\nthree")])
        XCTAssertEqual(all[0].agentName, "Claude Code")
    }

    func testAnotherAgentOrSessionStartsANewReply() {
        let items = build([line(1, "claude_code", "a"), line(2, "codex", "b"),
                           line(3, "codex", "c", session: "s2"), line(4, "codex", "d", session: "s2")])
        let all = replies(items)
        XCTAssertEqual(all.map(\.text), ["a", "b", "c\nd"])
        XCTAssertEqual(all.map(\.agent), ["claude_code", "codex", "codex"])
    }

    func testUserLinesAreBubblesAndBreakAReply() {
        let items = build([line(1, "claude_code", "answer"), line(2, "user", "next question"),
                           line(3, "claude_code", "more")])
        XCTAssertTrue(items.contains(.user(id: "u2", text: "next question")))
        XCTAssertEqual(replies(items).map(\.text), ["answer", "more"])
    }

    func testSystemLinesAreCentredNotices() {
        let items = build([line(1, "system", "Hub started", session: nil), line(2, "claude_code", "x"),
                           line(3, "system", "Connection lost", session: nil), line(4, "claude_code", "y")])
        XCTAssertTrue(items.contains(.system(id: "s1", text: "Hub started")))
        XCTAssertTrue(items.contains(.system(id: "s3", text: "Connection lost")))
        XCTAssertEqual(replies(items).map(\.text), ["x", "y"])
    }

    // MARK: Time labels

    func testTimeLabelsAppearBetweenGroupsNotPerMessage() {
        let items = build([
            line(1, "user", "q1", time: "2026-01-02T09:41:00Z"),
            line(2, "claude_code", "a1", time: "2026-01-02T09:41:05Z"),
            line(3, "user", "q2", time: "2026-01-02T09:41:20Z"),
            line(4, "codex", "a2", time: "2026-01-02T09:52:00Z"),
        ])
        let labels = items.compactMap { item -> String? in
            if case .separator(_, let text) = item { return text } else { return nil }
        }
        XCTAssertEqual(labels, ["Today, 09:41", "09:52"])
    }

    func testDayNamesForYesterdayAndOlderDays() {
        let items = build([
            line(1, "user", "old", time: "2025-12-30T08:00:00Z"),
            line(2, "user", "yesterday", time: "2026-01-01T09:00:00Z"),
        ])
        let labels = items.compactMap { item -> String? in
            if case .separator(_, let text) = item { return text } else { return nil }
        }
        XCTAssertEqual(labels, ["30 Dec, 08:00", "Yesterday, 09:00"])
    }

    func testLinesWithoutTimeGetNoLabel() {
        let items = build([line(1, "claude_code", "x", time: nil)])
        XCTAssertEqual(items.count, 1)
    }

    func testTimestampsParse() {
        XCTAssertNotNil(ChatTime.parse("2026-01-02T09:41:00Z"))
        XCTAssertNotNil(ChatTime.parse("2026-01-02T09:41:00.123456Z"))
        XCTAssertNotNil(ChatTime.parse("2026-01-02T09:41:00.123456"))
        XCTAssertNotNil(ChatTime.parse("2026-01-02T09:41:00"))
        XCTAssertNil(ChatTime.parse("later"))
        XCTAssertNil(ChatTime.parse(nil))
    }

    // MARK: Code fences

    func testFencedCodeBecomesACodeBlock() {
        let items = build([
            line(1, "claude_code", "Here it is:"),
            line(2, "claude_code", "```python"),
            line(3, "claude_code", "print(1)"),
            line(4, "claude_code", "print(2)"),
            line(5, "claude_code", "```"),
            line(6, "claude_code", "Done."),
        ])
        XCTAssertEqual(replies(items)[0].blocks, [
            .text("Here it is:"),
            .code(language: "python", source: "print(1)\nprint(2)"),
            .text("Done."),
        ])
    }

    func testAFenceInOneLineOfTextIsFound() {
        let blocks = ChatCode.parse("Intro\n```js\nlet a = 1\n```")
        XCTAssertEqual(blocks, [.text("Intro"), .code(language: "js", source: "let a = 1")])
    }

    func testAnOpenFenceIsCodeSoFar() {
        XCTAssertEqual(ChatCode.parse("```swift\nlet a = 1"), [.code(language: "swift", source: "let a = 1")])
    }

    func testCodeLanguageLabel() {
        XCTAssertEqual(ChatCode.displayName("python"), "Python")
        XCTAssertEqual(ChatCode.displayName(""), "Code")
    }

    // MARK: Caching

    func testTheBuilderReadsOnlyNewLinesAndMatchesAFullBuild() {
        let lines = [line(1, "user", "q"), line(2, "claude_code", "a"), line(3, "claude_code", "b"),
                     line(4, "codex", "c")]
        var incremental = ChatBuilder(calendar: calendar)
        XCTAssertTrue(incremental.sync(Array(lines[0..<2]), now: now))
        XCTAssertTrue(incremental.sync(lines, now: now))
        XCTAssertFalse(incremental.sync(lines, now: now), "nothing new")
        XCTAssertEqual(incremental.items, build(lines))
    }

    func testTheBuilderBuildsAgainWhenTheOldestLinesDrop() {
        let lines = [line(1, "claude_code", "a"), line(2, "claude_code", "b"), line(3, "codex", "c")]
        var builder = ChatBuilder(calendar: calendar)
        builder.sync(lines, now: now)
        let trimmed = Array(lines.dropFirst())
        XCTAssertTrue(builder.sync(trimmed, now: now))
        XCTAssertEqual(builder.items, build(trimmed))
        XCTAssertTrue(builder.sync([], now: now))
        XCTAssertEqual(builder.items, [])
    }

    // MARK: Streaming

    func testStreamingRule() {
        let last = now.addingTimeInterval(-3)
        let live = SessionInfo(id: "s1", agent: "claude_code", workingDirectory: nil, busy: true,
                               idleSeconds: nil, lastActivity: nil, lineCount: 0, fromLog: false)
        let idle = SessionInfo(id: "s1", agent: "claude_code", workingDirectory: nil, busy: false,
                               idleSeconds: nil, lastActivity: nil, lineCount: 0, fromLog: false)
        let derived = SessionInfo(id: "s1", agent: "claude_code", workingDirectory: nil, busy: false,
                                  idleSeconds: nil, lastActivity: nil, lineCount: 4, fromLog: true)
        XCTAssertTrue(ChatStreaming.isStreaming(lastLineTime: last, now: now, isLastItem: true, session: live))
        XCTAssertTrue(ChatStreaming.isStreaming(lastLineTime: last, now: now, isLastItem: true, session: derived))
        XCTAssertTrue(ChatStreaming.isStreaming(lastLineTime: last, now: now, isLastItem: true, session: nil))
        XCTAssertFalse(ChatStreaming.isStreaming(lastLineTime: last, now: now, isLastItem: true, session: idle),
                       "an idle live session is not answering")
        XCTAssertFalse(ChatStreaming.isStreaming(lastLineTime: last, now: now, isLastItem: false, session: live),
                       "only the last reply streams")
        XCTAssertFalse(ChatStreaming.isStreaming(lastLineTime: now.addingTimeInterval(-9), now: now,
                                                 isLastItem: true, session: live),
                       "a line older than eight seconds ends the stream")
        XCTAssertTrue(ChatStreaming.isStreaming(lastLineTime: now.addingTimeInterval(-7.9), now: now,
                                                isLastItem: true, session: live))
        XCTAssertFalse(ChatStreaming.isStreaming(lastLineTime: nil, now: now, isLastItem: true, session: live))
    }

    // MARK: Relative time text

    func testUpdatedText() {
        XCTAssertEqual(Format.updated(from: nil, to: now), "Not updated yet")
        XCTAssertEqual(Format.updated(from: now, to: now), "Updated just now")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-9), to: now), "Updated just now")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-10), to: now), "Updated 10s ago")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-50), to: now), "Updated 50s ago")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-60), to: now), "Updated 1 min ago")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-3600), to: now), "Updated 1 h ago")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(5), to: now), "Updated just now")
    }

    // MARK: Composer agents

    func testAgentOrderIsFixed() {
        XCTAssertEqual(ComposerAgents.all.map(\.id), ["claude_code", "codex", "antigravity", "deepseek"])
        XCTAssertEqual(ComposerAgents.all.map(\.name), ["Claude Code", "Codex", "AntiGravity", "DeepSeek"])
        XCTAssertEqual(ComposerAgents.name(for: "antigravity"), "AntiGravity")
    }

    // MARK: Tab bar

    func testHeroTabAccessibility() {
        XCTAssertEqual(Screen.phoneOrder, [.sessions, .pipelines, .console, .usage, .settings])
        let items = TabBarItem.items()
        XCTAssertEqual(items.map(\.identifier),
                       ["tab-sessions", "tab-pipelines", "tab-console", "tab-usage", "tab-settings"])
        XCTAssertEqual(items.map(\.accessibilityLabel), ["Sessions", "Pipelines", "Console", "Usage", "Settings"])
        XCTAssertEqual(items.map(\.accessibilityValue),
                       ["tab 1 of 5", "tab 2 of 5", "tab 3 of 5", "tab 4 of 5", "tab 5 of 5"])
        XCTAssertEqual(items[2].accessibilityHint, "Shows Console")
        XCTAssertEqual(items.filter(\.isHero).map(\.screen), [.console])
        XCTAssertEqual(Screen.allCases.first, .console, "the iPad sidebar lists Console first")
    }

    func testTabBarRoomForContent() {
        XCTAssertEqual(TabBarMetrics.bottomGap(safeBottom: 34), 18)
        XCTAssertEqual(TabBarMetrics.bottomGap(safeBottom: 0), 12)
        XCTAssertEqual(TabBarMetrics.reserve(safeBottom: 34), 106)
        XCTAssertEqual(TabBarMetrics.contentInset(safeBottom: 34), 72)
        XCTAssertEqual(TabBarMetrics.contentInset(safeBottom: 0), 100)
    }

    // MARK: Route pill

    func testRoutePillWords() {
        XCTAssertEqual(RoutePill.label(route: .lan, connecting: false), "LAN")
        XCTAssertEqual(RoutePill.label(route: .direct, connecting: false), "Direct")
        XCTAssertEqual(RoutePill.label(route: .relay, connecting: false), "Relay")
        XCTAssertEqual(RoutePill.label(route: .offline, connecting: false), "Offline")
        XCTAssertEqual(RoutePill.label(route: .offline, connecting: true), "Connecting")
    }

    // MARK: Machine rename

    func testRenamingAMachineKeepsTheKeyAndSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let payload = PairingPayload(version: 1, name: "Test Hub", lanHost: "192.0.2.10", lanPort: 18845,
                                     fingerprint: String(repeating: "a", count: 64),
                                     hubId: Data(repeating: 0x42, count: 16),
                                     key: Data(repeating: 0x41, count: 32), irohTicket: nil)
        let store = HubStore(secrets: secrets, directory: directory)
        let record = try store.add(payload: payload)
        XCTAssertFalse(store.rename(id: record.id, to: "   "), "an empty name is ignored")
        XCTAssertFalse(store.rename(id: "missing", to: "Other"))
        XCTAssertFalse(store.rename(id: record.id, to: "Test Hub"), "the same name is no change")
        XCTAssertTrue(store.rename(id: record.id, to: "  Studio  "))
        XCTAssertEqual(store.hubs.first?.name, "Studio")
        let reopened = HubStore(secrets: secrets, directory: directory)
        XCTAssertEqual(reopened.hubs.first?.name, "Studio")
        XCTAssertNotNil(try reopened.key(for: record.id))
    }
}
