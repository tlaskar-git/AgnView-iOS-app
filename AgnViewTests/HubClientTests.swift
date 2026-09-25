import XCTest
@testable import AgnView

final class HubClientTests: XCTestCase {
    private let base = URL(string: "http://192.0.2.10:18845")
    private let token = "example-token-not-real"

    override func setUp() {
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
    }

    private func makeClient() -> HubClient {
        HubClient(baseURL: base, token: token, session: StubURLProtocol.session())
    }

    private func answer(_ status: Int, _ body: String) {
        StubURLProtocol.handler = { _ in .response(status, Data(body.utf8)) }
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

    func testUsageAccounts() async throws {
        answer(200, SampleJSON.usage)
        let accounts = try await makeClient().usageAccounts()
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].providerKind, .claude)
        XCTAssertEqual(accounts[0].tokensUsed, 1200)
        XCTAssertEqual(accounts[0].tokensLimit, 10000)
        XCTAssertNil(accounts[0].costLimit)
        XCTAssertEqual(accounts[1].providerKind, .gemini)
        XCTAssertFalse(accounts[1].isActive)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.path, "/api/usage/accounts")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["X-AgnView-Token"], token)
    }

    func testStatus() async throws {
        answer(200, SampleJSON.status)
        let status = try await makeClient().status()
        XCTAssertEqual(status.status, "healthy")
        XCTAssertEqual(status.version, "0.0.0-test")
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/mobile/status")
    }

    func testJobsWithTasks() async throws {
        answer(200, SampleJSON.jobs)
        let jobs = try await makeClient().jobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].status, .inProgress)
        XCTAssertEqual(jobs[0].tasks.count, 1)
        XCTAssertEqual(jobs[0].tasks[0].status, .ready)
        XCTAssertEqual(jobs[0].tasks[0].jobId, "job-1")
        XCTAssertEqual(jobs[0].tasks[0].dependencies, ["task-0"])
        XCTAssertNil(jobs[0].tasks[0].outputSummary)
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/jobs")
    }

    func testUnknownEnumCasesAreTolerated() async throws {
        answer(200, """
        [{"id":"job-9","title":"Future","status":"archived","extra_field":1,
          "tasks":[{"id":"t","title":"T","status":"paused"}]}]
        """)
        let jobs = try await makeClient().jobs()
        XCTAssertEqual(jobs[0].status, .unknown("archived"))
        XCTAssertEqual(jobs[0].tasks[0].status, .unknown("paused"))
        XCTAssertEqual(Provider(raw: "mistral"), .unknown("mistral"))
        XCTAssertEqual(AgentKind(raw: "future_agent").raw, "future_agent")
        XCTAssertEqual(AgentKind(raw: "claude_code"), .claudeCode)
    }

    func testLiveSessions() async throws {
        answer(200, SampleJSON.liveSessions)
        let sessions = try await makeClient().liveSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionId, "session-1")
        XCTAssertEqual(sessions[0].id, "session-1")
        XCTAssertEqual(sessions[0].workingDirectory, "example-project")
        XCTAssertTrue(sessions[0].busy)
        XCTAssertEqual(sessions[0].idleSeconds, 12.5)
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/console/live-sessions")
    }

    func testDispatchBodyAndResponse() async throws {
        answer(200, SampleJSON.dispatch)
        let response = try await makeClient().dispatch(DispatchRequest(targetAgent: "claude_code",
                                                                       prompt: "Example prompt"))
        XCTAssertEqual(response.status, "dispatched")
        XCTAssertEqual(response.sessionId, "sess-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/console/dispatch")
        XCTAssertEqual(request.headers["X-AgnView-Token"], token)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["agent"] as? String, "claude_code")
        XCTAssertEqual(json["prompt"] as? String, "Example prompt")
        XCTAssertTrue(json["working_directory"] is NSNull)
        XCTAssertTrue(json["session_id"] is NSNull)
    }

    func testDispatchWithSessionAndDirectory() async throws {
        answer(200, "{}")
        _ = try await makeClient().dispatch(DispatchRequest(targetAgent: "codex", prompt: "p",
                                                            workingDir: "example-project", sessionId: "s-1"))
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["working_directory"] as? String, "example-project")
        XCTAssertEqual(json["session_id"] as? String, "s-1")
    }

    func testStatusCodeMapping() async {
        let client = makeClient()
        answer(401, #"{"detail":"Unauthorized"}"#)
        await assertFails(.unauthorised) { _ = try await client.usageAccounts() }
        answer(429, #"{"detail":"Too many"}"#)
        await assertFails(.rateLimited) { _ = try await client.jobs() }
        answer(500, "oops")
        await assertFails(.protocolViolation) { _ = try await client.liveSessions() }
        answer(401, "{}")
        await assertFails(.unauthorised) {
            _ = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: "p"))
        }
    }

    func testNetworkErrorsMapToUnreachable() async {
        let client = makeClient()
        StubURLProtocol.handler = { _ in .failure(URLError(.notConnectedToInternet)) }
        await assertFails(.unreachable) { _ = try await client.status() }
        StubURLProtocol.handler = { _ in .failure(URLError(.cannotConnectToHost)) }
        await assertFails(.unreachable) { _ = try await client.usageAccounts() }
        StubURLProtocol.handler = { _ in .failure(URLError(.timedOut)) }
        await assertFails(.timedOut) { _ = try await client.jobs() }
    }

    func testBadBodyIsProtocolViolation() async {
        answer(200, "not json")
        let client = makeClient()
        await assertFails(.protocolViolation) { _ = try await client.usageAccounts() }
    }

    func testMissingBaseURLIsUnreachable() async {
        let client = HubClient(baseURL: nil, token: token, session: StubURLProtocol.session())
        await assertFails(.unreachable) { _ = try await client.status() }
    }
}
