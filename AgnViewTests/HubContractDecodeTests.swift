import XCTest
@testable import AgnView

/// Decodes sanitised responses captured from a real AgnView 0.1.8 hub (see
/// Tools/contract). These tests exist because the first version of the app was
/// only ever tested against a mock built from the API document.
final class HubContractDecodeTests: XCTestCase {
    private let token = "example-token-not-real"

    override func setUp() {
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
    }

    // MARK: Fixtures

    private static func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.8")
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func fixture(_ name: String) throws -> Data {
        try HubContractDecodeTests.fixture(name)
    }

    private func makeClient() -> HubClient {
        HubClient(baseURL: URL(string: "http://192.0.2.10:8765"), token: token,
                  session: StubURLProtocol.session())
    }

    private func answer(_ status: Int, _ data: Data) {
        StubURLProtocol.handler = { _ in .response(status, data) }
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

    // MARK: Status

    func testRealStatusDecodes() async throws {
        answer(200, try fixture("status.json"))
        let status = try await makeClient().status()
        XCTAssertEqual(status.status, "healthy")
        XCTAssertEqual(status.service, "AgnView")
        XCTAssertEqual(status.version, "")
        XCTAssertEqual(status.bindMode, "loopback")
        XCTAssertEqual(status.transportLabel, "Loopback only")
        XCTAssertEqual(status.resolvedTransport, "offline")
        XCTAssertNil(status.pairedAgentsOnline)
    }

    func testStatusWithOnlyStatusStillDecodes() throws {
        let status = try MobileStatus.decode(from: Data(#"{"status":"healthy"}"#.utf8))
        XCTAssertEqual(status.status, "healthy")
        XCTAssertEqual(status.service, "AgnView")
    }

    // MARK: Usage

    func testEmptyUsageList() async throws {
        answer(200, try fixture("usage_accounts_empty.json"))
        let accounts = try await makeClient().usageAccounts()
        XCTAssertEqual(accounts, [])
    }

    func testRealUsageAccountsDecode() async throws {
        answer(200, try fixture("usage_accounts.json"))
        let client = makeClient()
        let accounts = try await client.usageAccounts()
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(client.droppedElements, 0)
        XCTAssertEqual(Set(accounts.map { $0.provider }), ["claude", "chatgpt", "gemini", "deepseek"])
        for account in accounts {
            // The hub sends null for every figure it has not measured.
            XCTAssertEqual(account.tokensUsed, 0)
            XCTAssertNil(account.tokensLimit)
            XCTAssertEqual(account.costUsed, 0)
            XCTAssertNil(account.costLimit)
            XCTAssertEqual(account.requestsCount, 0)
            XCTAssertEqual(account.status, "unavailable")
            XCTAssertFalse(account.isActive)
            XCTAssertNotNil(account.lastProbed)
            XCTAssertNotNil(account.errorMessage)
            XCTAssertNotNil(HubDate.parse(account.lastProbed))
        }
        XCTAssertEqual(accounts.first { $0.provider == "claude" }?.providerKind, .claude)
    }

    func testMeasuredUsageAccountDecodes() throws {
        let json = """
        [{"id":"claude-abc123","provider":"claude","name":"Example","plan_name":"Pro",
          "tokens_used":1200,"tokens_limit":10000,"cost_used_usd":1.5,"cost_limit_usd":null,
          "requests_used":7,"percent_used":12.0,"session_percent_used":4.0,"weekly_percent_used":null,
          "status":"active","last_checked":"2026-01-01T00:00:00.123456+00:00"}]
        """
        let account = try XCTUnwrap(UsageAccount.decodeList(from: Data(json.utf8)).first)
        XCTAssertEqual(account.tokensUsed, 1200)
        XCTAssertEqual(account.tokensLimit, 10000)
        XCTAssertEqual(account.costUsed, 1.5)
        XCTAssertNil(account.costLimit)
        XCTAssertEqual(account.requestsCount, 7)
        XCTAssertEqual(account.percentUsed, 12.0)
        XCTAssertEqual(account.sessionPercentUsed, 4.0)
        XCTAssertNil(account.weeklyPercentUsed)
        XCTAssertTrue(account.isActive)
    }

    // MARK: Jobs

    func testJobsWithTasksAsObject() async throws {
        answer(200, try fixture("jobs_after.json"))
        let client = makeClient()
        let jobs = try await client.jobs()
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(client.droppedElements, 0)
        let failed = try XCTUnwrap(jobs.first { $0.id == "job-probe-b" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.tasks.map { $0.id }, ["b-one", "b-two"])
        XCTAssertEqual(failed.tasks.map { $0.status }, [.failed, .blocked])
        XCTAssertEqual(failed.tasks[1].dependencies, ["b-one"])
        XCTAssertEqual(failed.tasks[0].outputSummary, "Probe failure")
        XCTAssertEqual(failed.droppedTasks, 0)
        let running = try XCTUnwrap(jobs.first { $0.id == "job-probe-a" })
        XCTAssertEqual(running.status, .inProgress)
        XCTAssertEqual(running.tasks.map { $0.id }, ["a-build", "a-review"])
        XCTAssertEqual(running.tasks[0].status, .completed)
        XCTAssertEqual(running.tasks[0].assignedAgent, "claude_code")
        XCTAssertEqual(running.tasks[0].jobId, "job-probe-a")
        XCTAssertNotNil(HubDate.parse(running.createdAt))
    }

    func testFreshJobsHaveReadyAndPendingTasks() async throws {
        answer(200, try fixture("jobs_fresh.json"))
        let jobs = try await makeClient().jobs()
        let statuses = jobs.flatMap { $0.tasks.map { $0.status } }
        XCTAssertTrue(statuses.contains(.ready))
        XCTAssertTrue(statuses.contains(.pending))
        XCTAssertTrue(jobs.allSatisfy { $0.status == .pending })
    }

    func testJobsInProgressFixture() async throws {
        answer(200, try fixture("jobs_in_progress.json"))
        let jobs = try await makeClient().jobs()
        let statuses = jobs.flatMap { $0.tasks.map { $0.status } }
        XCTAssertTrue(statuses.contains(.inProgress))
    }

    func testSingleJobDecodes() throws {
        let job = try HubJSON.decode(Job.self, from: try fixture("job_single.json"))
        XCTAssertEqual(job.id, "job-probe-a")
        XCTAssertEqual(job.tasks.count, 2)
    }

    func testEmptyJobsList() async throws {
        answer(200, Data("[]".utf8))
        let jobs = try await makeClient().jobs()
        XCTAssertEqual(jobs, [])
    }

    func testTasksAsArrayStillDecode() throws {
        let json = #"[{"id":"j","title":"T","status":"pending","tasks":[{"id":"t1","title":"One","status":"ready"}]}]"#
        let jobs = try HubList.decode(Job.self, from: Data(json.utf8)).items
        XCTAssertEqual(jobs[0].tasks.map { $0.id }, ["t1"])
    }

    func testOddJobsAndTasksAreDroppedAndCounted() async throws {
        let json = """
        [ {"id":"good","title":"Good","status":"pending","tasks":{
             "a":{"id":"a","title":"A","status":"weird_new_status","dependencies":null},
             "b":42,
             "c":{"title":"no id"}}},
          17,
          {"title":"no id at all"},
          {"id":5,"title":null,"status":null,"tasks":null,"created_at":12345} ]
        """
        answer(200, Data(json.utf8))
        let client = makeClient()
        let jobs = try await client.jobs()
        XCTAssertEqual(jobs.map { $0.id }, ["good", "5"])
        XCTAssertEqual(client.droppedElements, 2)
        XCTAssertEqual(jobs[0].tasks.map { $0.id }, ["a"])
        XCTAssertEqual(jobs[0].droppedTasks, 2)
        XCTAssertEqual(jobs[0].tasks[0].status, .unknown("weird_new_status"))
        XCTAssertEqual(jobs[0].tasks[0].dependencies, [])
        XCTAssertEqual(jobs[1].tasks, [])
        XCTAssertEqual(jobs[1].title, "")
        XCTAssertEqual(jobs[1].createdAt, "12345")
    }

    func testEnvelopeIsUnwrapped() async throws {
        answer(200, Data(#"{"jobs":[{"id":"j1","title":"T","status":"completed","tasks":{}}]}"#.utf8))
        let jobs = try await makeClient().jobs()
        XCTAssertEqual(jobs.map { $0.id }, ["j1"])
    }

    func testBodyThatIsNotAListIsAProtocolViolation() async {
        answer(200, Data(#"{"detail":"nothing here"}"#.utf8))
        await assertFails(.protocolViolation) { _ = try await makeClient().jobs() }
    }

    // MARK: Console

    func testConsoleLogsDecode() throws {
        let rows = try HubList.decode(ConsoleFrame.LogEntry.self, from: try fixture("console_logs.json"),
                                      decoder: JSONDecoder())
        XCTAssertEqual(rows.dropped, 0)
        XCTAssertEqual(rows.items.map { $0.id }, [1, 2, 3])
        XCTAssertEqual(rows.items.map { $0.source }, ["user_input", "agent_stdout", "system_notice"])
        XCTAssertEqual(rows.items[0].agent, "codex")
        XCTAssertEqual(rows.items[0].content, "probe prompt")
        XCTAssertNotNil(rows.items[0].sessionId)
        XCTAssertNotNil(HubDate.parse(rows.items[0].timestamp))
    }

    func testEmptyConsoleLogs() throws {
        let rows = try HubList.decode(ConsoleFrame.LogEntry.self, from: try fixture("console_logs_empty.json"),
                                      decoder: JSONDecoder())
        XCTAssertEqual(rows.items, [])
    }

    func testOddLogRowsDoNotFailTheBatch() throws {
        let json = """
        [{"id":1,"agent":"codex","source":"agent_stdout","content":"ok","timestamp":"t","session_id":null,"metadata":{}},
         "junk",
         {"id":"2","agent":7,"source":null,"content":12,"timestamp":null,"session_id":"s"}]
        """
        let rows = try HubList.decode(ConsoleFrame.LogEntry.self, from: Data(json.utf8), decoder: JSONDecoder())
        XCTAssertEqual(rows.items.count, 2)
        XCTAssertEqual(rows.dropped, 1)
        XCTAssertEqual(rows.items[1].id, 2)
        XCTAssertEqual(rows.items[1].agent, "7")
        XCTAssertEqual(rows.items[1].content, "12")
    }

    func testLiveSessionsEmpty() async throws {
        answer(200, try fixture("live_sessions_empty.json"))
        let sessions = try await makeClient().liveSessions()
        XCTAssertEqual(sessions, [])
    }

    func testLiveSessionsFromHubSource() async throws {
        answer(200, try fixture("live_sessions_from_source.json"))
        let sessions = try await makeClient().liveSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sessionId, "sess-00000000")
        XCTAssertTrue(sessions[0].busy)
        XCTAssertEqual(sessions[0].idleSeconds, 3.25)
        XCTAssertEqual(sessions[1].sessionId, "antigravity@/home/example/other")
        XCTAssertFalse(sessions[1].busy)
    }

    // MARK: Dispatch

    func testRealDispatchResponse() async throws {
        answer(200, try fixture("dispatch_response.json"))
        let response = try await makeClient().dispatch(DispatchRequest(targetAgent: "codex", prompt: "p"))
        XCTAssertEqual(response.status, "dispatched")
        XCTAssertEqual(response.agent, "codex")
        XCTAssertEqual(response.sessionId?.hasPrefix("sess-"), true)
        XCTAssertNotNil(response.message)
    }

    func testDispatchBodyUsesTheKeysTheHubReads() async throws {
        answer(200, try fixture("dispatch_response.json"))
        _ = try await makeClient().dispatch(DispatchRequest(targetAgent: "codex", prompt: "p",
                                                            workingDir: "example-project", sessionId: "s"))
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["agent", "prompt", "working_directory", "session_id"])
        XCTAssertNil(json["target_agent"])
        XCTAssertNil(json["working_dir"])
    }

    // MARK: Error bodies

    func testRealUnauthorisedBody() async throws {
        answer(401, try fixture("error_401.json"))
        await assertFails(.unauthorised) { _ = try await makeClient().status() }
        await assertFails(.unauthorised) { _ = try await makeClient().jobs() }
    }

    func testRealRateLimitBody() async throws {
        answer(429, try fixture("error_429.json"))
        await assertFails(.rateLimited) { _ = try await makeClient().status() }
    }

    func testRealValidationAndNotFoundBodies() async throws {
        answer(422, try fixture("error_422.json"))
        await assertFails(.protocolViolation) {
            _ = try await makeClient().dispatch(DispatchRequest(targetAgent: "codex", prompt: "p"))
        }
        answer(404, try fixture("error_404.json"))
        await assertFails(.protocolViolation) { _ = try await makeClient().jobs() }
    }

    func testTokenHeaderIsTheOneTheHubReads() async throws {
        answer(200, try fixture("status.json"))
        _ = try await makeClient().status()
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.headers["X-AgnView-Token"], token)
        XCTAssertNil(request.headers["X-Pairing-Key"])
    }

    // MARK: Events

    func testRealEventStreamDecodes() throws {
        var decoder = SSEDecoder()
        let events = try decoder.feed(try fixture("events_stream.txt"))
        XCTAssertEqual(events.map { $0.type },
                       ["connected", "agent_output_chunk", "agent_output_chunk", "agent_finished"])
        let connected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(events[0].data.utf8)) as? [String: Any])
        XCTAssertEqual(connected["status"] as? String, "connected")
        let chunk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(events[1].data.utf8)) as? [String: Any])
        XCTAssertEqual(chunk["event_type"] as? String, "agent_output_chunk")
        XCTAssertNotNil(chunk["payload"] as? [String: Any])
    }

    func testEventStreamSplitAcrossChunksDecodesTheSame() throws {
        let data = try fixture("events_stream.txt")
        var decoder = SSEDecoder()
        var events: [SSEEvent] = []
        for byte in data { events += try decoder.feed(Data([byte])) }
        XCTAssertEqual(events.count, 4)
    }

    // MARK: Dates

    func testHubDateFormats() {
        XCTAssertNotNil(HubDate.parse("2026-09-25T10:21:49.934690+00:00"))
        XCTAssertNotNil(HubDate.parse("2026-09-25T10:23:12.091991Z"))
        XCTAssertNotNil(HubDate.parse("2026-09-25 10:23:28.185966+00:00"))
        XCTAssertNotNil(HubDate.parse("2026-09-25T10:23:28"))
        XCTAssertNotNil(HubDate.parse("2026-09-25T10:23:28+0000"))
        XCTAssertEqual(HubDate.parse("1767225600"), Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertNil(HubDate.parse(nil))
        XCTAssertNil(HubDate.parse("not a date"))
        let a = HubDate.parse("2026-09-25T10:21:49.934690+00:00")
        let b = HubDate.parse("2026-09-25T10:21:49Z")
        XCTAssertEqual(try XCTUnwrap(a).timeIntervalSince(try XCTUnwrap(b)), 0.934, accuracy: 0.001)
    }
}
