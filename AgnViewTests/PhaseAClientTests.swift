import XCTest
@testable import AgnView

/// The calls added in phase A, against a stubbed hub.
final class PhaseAClientTests: XCTestCase {
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

    private func fixture(_ name: String, file: StaticString = #filePath) throws -> String {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.12")
        return try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func draft() -> PipelineDraft {
        var draft = PipelineDraft(idSeed: "ab12")
        draft.title = "Example pipeline"
        draft.tasks[0].title = "Build"
        return draft
    }

    // MARK: Composer

    func testCapabilitiesAndFilesPaths() async throws {
        answer(200, try fixture("system_capabilities.json"))
        let catalogue = try await makeClient().capabilities()
        XCTAssertEqual(catalogue.modelOptions(for: "claude_code").count, 4)
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/system/capabilities")
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "GET")

        answer(200, try fixture("system_files.json"))
        let files = try await makeClient().files()
        XCTAssertEqual(files.files.count, 3)
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/api/system/files")
        XCTAssertNil(StubURLProtocol.requests.last?.url.query)

        _ = try await makeClient().files(directory: "example project")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.query, "cwd=example%20project")
    }

    func testLogsQueryAsksForTheNewestRowsOrTheOnesAfterAnId() async throws {
        answer(200, #"[{"id":7,"agent":"codex","source":"stdout","content":"x","timestamp":"2026-01-01T00:00:00Z","session_id":"s-1"}]"#)
        let rows = try await makeClient().logs()
        XCTAssertEqual(rows.first?.sessionId, "s-1")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.query, "agent=all&limit=250")
        _ = try await makeClient().logs(afterId: 7, limit: 5000)
        XCTAssertEqual(StubURLProtocol.requests.last?.url.query, "agent=all&limit=1000&after_id=7")
    }

    // MARK: Pipelines

    func testCreateJobPostsTheBodyAndDecodesTheJob() async throws {
        answer(200, try fixture("job_created.json"))
        var draft = draft()
        draft.attachments = [.forHubPath("README.md")]
        let job = try await makeClient().createJob(draft.requestBody())
        XCTAssertEqual(job.id, "job-example")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/jobs")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Example pipeline")
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.first?["id"] as? String, "task-ab12-1")
        XCTAssertEqual(tasks.first?["description"] as? String, "[Context Files: README.md]")
    }

    func testCreateJobRefusalCarriesTheHubReason() async {
        answer(400, #"{"detail":"Task 'a' is assigned to unknown agent 'x'. Known agents: codex."}"#)
        do {
            _ = try await makeClient().createJob(draft().requestBody())
            XCTFail("expected a refusal")
        } catch {
            let rejection = error as? HubRejection
            XCTAssertEqual(rejection?.status, 400)
            XCTAssertEqual(rejection?.errorDescription, "Task 'a' is assigned to unknown agent 'x'. Known agents: codex.")
        }
    }

    func testValidationListGivesItsFirstMessage() {
        let body = Data(#"{"detail":[{"type":"missing","loc":["body","title"],"msg":"Field required"}]}"#.utf8)
        XCTAssertEqual(HubRejection.detail(in: body), "Field required")
        XCTAssertNil(HubRejection.detail(in: Data("not json".utf8)))
        XCTAssertEqual(HubRejection(status: 409, detail: nil).errorDescription,
                       "The hub cannot do that in the current state.")
    }

    func testDeleteJobUsesDelete() async throws {
        answer(200, #"{"message":"Job 'job-1' deleted successfully."}"#)
        try await makeClient().deleteJob(id: "job-1")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.path, "/api/jobs/job-1")
    }

    func testDeleteMissingJobIsARejection() async {
        answer(404, #"{"detail":"Job 'gone' not found."}"#)
        do {
            try await makeClient().deleteJob(id: "gone")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HubRejection)?.status, 404)
        }
    }

    func testUnsafeIdsNeverReachThePath() async {
        answer(200, "{}")
        do {
            try await makeClient().deleteJob(id: "../etc")
            XCTFail("expected a protocol violation")
        } catch {
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRequestRevisionAndFailBodies() async throws {
        answer(200, "{}")
        try await makeClient().requestRevision(taskId: "task-1", feedback: "Tighten it")
        var request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/api/tasks/task-1/request-revision")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(object["feedback"], "Tighten it")
        XCTAssertEqual(object["from_agent"], "user")

        try await makeClient().failTask(taskId: "task-1", reason: "Wrong approach")
        request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url.path, "/api/tasks/task-1/fail")
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(object["reason"], "Wrong approach")
    }

    func testFailWithoutAReasonIsRefusedByTheHubWithItsMessage() async {
        answer(422, #"{"detail":"A failure reason is required."}"#)
        do {
            try await makeClient().failTask(taskId: "task-1", reason: " ")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HubRejection)?.errorDescription, "A failure reason is required.")
        }
    }

    // MARK: Usage refresh

    func testRefreshAllPostsAndDecodesTheAccounts() async throws {
        answer(200, try fixture("usage_accounts_windows.json"))
        let accounts = try await makeClient().refreshAllUsage()
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.first?.url.path, "/api/usage/refresh-all")
    }

    func testAuthFailuresStillMapToTransportErrors() async {
        answer(401, #"{"detail":"Unauthorized"}"#)
        do {
            try await makeClient().deleteJob(id: "job-1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorised)
        }
        answer(500, "boom")
        do {
            _ = try await makeClient().refreshAllUsage()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TransportError, .protocolViolation)
        }
    }

    func testRefreshAllGetsALongerTimeThanOrdinaryCalls() throws {
        let lan = LANTransport(baseURL: base, token: token, session: StubURLProtocol.session(), requestTimeout: 10)
        let ordinary = try lan.makeRequest("/api/usage/accounts")
        XCTAssertEqual(ordinary.timeoutInterval, 10)
        let long = try lan.makeRequest(HubPath.usageRefreshAll, method: "POST", timeout: 60)
        XCTAssertEqual(long.timeoutInterval, 60)
    }
}
