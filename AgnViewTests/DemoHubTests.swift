import XCTest
@testable import AgnView

/// A secret store that counts what is written to it.
private final class CountingSecretStore: SecretStore {
    private let lock = NSLock()
    private(set) var writes = 0

    func get(account: String) throws -> Data? { nil }

    func set(_ data: Data, account: String) throws {
        lock.lock()
        writes += 1
        lock.unlock()
    }

    func delete(account: String) throws {}
}

final class DemoHubTests: XCTestCase {
    private func makeHub() -> DemoHub { DemoHub(replyDelay: 0) }

    // MARK: Usage

    func testUsageAccountsCarryWindowsBreakdownAndOneStaleReading() async throws {
        let client = HubClient(api: makeHub())
        let accounts = try await client.usageAccounts()
        XCTAssertGreaterThanOrEqual(accounts.count, 3)
        XCTAssertTrue(accounts.allSatisfy { $0.hasWindows })
        XCTAssertEqual(accounts.filter { $0.usage?.isStale == true }.count, 1)
        XCTAssertTrue(accounts.contains { account in
            account.usage?.windows.contains { !$0.breakdown.isEmpty } == true
        })
        let percents = accounts.flatMap { $0.usage?.windows ?? [] }.compactMap { $0.percentUsed }
        XCTAssertTrue(percents.allSatisfy { $0 >= 0 && $0 <= 100 })
        XCTAssertTrue(accounts.allSatisfy { $0.usage?.windows.first?.countdownText?.hasPrefix("Resets in") == true })
        XCTAssertEqual(Set(accounts.map { $0.provider }).count, accounts.count)
    }

    func testRefreshAllMakesFreshReadingsAndKeepsTheStaleOne() async throws {
        let client = HubClient(api: makeHub())
        let before = try await client.usageAccounts()
        let after = try await client.refreshAllUsage()
        XCTAssertEqual(before.map { $0.id }, after.map { $0.id })
        XCTAssertEqual(after.filter { $0.usage?.isStale == true }.count, 1)
        let fresh = after.filter { $0.usage?.isStale == false }
        XCTAssertTrue(fresh.allSatisfy { ($0.usage?.ageSeconds ?? 999) < 60 })
    }

    // MARK: Catalogue and files

    func testCatalogueListsModelsAndEffortsForEveryAgent() async throws {
        let client = HubClient(api: makeHub())
        let catalogue = try await client.capabilities()
        for agent in ["claude_code", "codex", "antigravity"] {
            XCTAssertTrue(catalogue.hasNamedModels(for: agent), agent)
            XCTAssertGreaterThan(catalogue.effortOptions(for: agent).count, 1, agent)
            XCTAssertTrue(catalogue.isAvailable(agent), agent)
        }
        XCTAssertEqual(catalogue.currentDirectory, DemoData.workingDirectory)
    }

    func testFilesAreListed() async throws {
        let client = HubClient(api: makeHub())
        let files = try await client.files()
        XCTAssertEqual(files.files, DemoData.files)
        XCTAssertFalse(files.files.isEmpty)
    }

    // MARK: Sessions and console

    func testLiveSessionsCoverThreeAgents() async throws {
        let client = HubClient(api: makeHub())
        let sessions = try await client.liveSessions()
        XCTAssertEqual(Set(sessions.compactMap { $0.agent }), ["claude_code", "codex", "antigravity"])
        XCTAssertEqual(Set(sessions.map { $0.sessionId }).count, 3)
    }

    func testConsoleBacklogCoversThreeAgentsAndPagesByIdAfter() async throws {
        let hub = makeHub()
        let client = HubClient(api: hub)
        let rows = try await client.logs()
        XCTAssertEqual(rows.count, DemoData.backlog.count)
        XCTAssertEqual(Set(rows.compactMap { $0.agent }).intersection(["claude_code", "codex", "antigravity"]).count, 3)
        XCTAssertEqual(rows.compactMap { $0.id }, Array(1...DemoData.backlog.count))
        let later = try await client.logs(afterId: 10)
        XCTAssertEqual(later.compactMap { $0.id }, Array(11...DemoData.backlog.count))
    }

    func testSessionStreamReplaysBacklogThenAddsLiveLines() async throws {
        let hub = makeHub()
        let session = hub.makeSession(interval: 0.01)
        var logs: [ConsoleFrame.LogEntry] = []
        var sawHello = false
        for try await frame in session.frames {
            switch frame {
            case .hello: sawHello = true
            case .log(let entry): logs.append(entry)
            default: break
            }
            if logs.count >= DemoData.backlog.count + 2 { break }
        }
        await session.close()
        XCTAssertTrue(sawHello)
        XCTAssertEqual(logs.prefix(DemoData.backlog.count).map { $0.content ?? "" }, DemoData.backlog.map { $0.content })
        XCTAssertEqual(logs[DemoData.backlog.count].content, DemoData.live[0].content)
        XCTAssertEqual(session.route, .lan)
        XCTAssertEqual(session.capabilities, .lan)
    }

    // MARK: Dispatch

    func testDispatchAppendsThePromptAndACannedFakeReply() async throws {
        let hub = makeHub()
        let client = HubClient(api: hub)
        let before = hub.consoleEntries.count
        let response = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: "Hello demo",
                                                                   model: "demo-fast", effort: "low"))
        XCTAssertEqual(response.status, "dispatched")
        XCTAssertEqual(response.agent, "codex")
        XCTAssertEqual(response.sessionId, DemoData.codexSession)
        let added = Array(hub.consoleEntries.dropFirst(before))
        XCTAssertEqual(added.first?.source, "user_input")
        XCTAssertEqual(added.first?.content, "Hello demo")
        XCTAssertTrue(added.contains { $0.content?.contains("Demo reply") == true })
        XCTAssertTrue(added.contains { $0.content?.contains("No real agent ran") == true })
        XCTAssertTrue(added.contains { $0.content?.contains("Hello demo") == true && $0.agent == "codex" })
        XCTAssertEqual(added.last?.content, "Finished")
    }

    func testDispatchWithoutAPromptIsRefused() async throws {
        let client = HubClient(api: makeHub())
        do {
            _ = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: "   "))
            XCTFail("an empty prompt must be refused")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testDispatchMentionsAttachedFiles() async throws {
        let hub = makeHub()
        let client = HubClient(api: hub)
        _ = try await client.dispatch(DispatchRequest(targetAgent: "claude_code", prompt: "Look",
                                                       files: ["README.md", "docs/notes.md"]))
        XCTAssertTrue(hub.consoleEntries.contains { $0.content == "Attached: README.md, docs/notes.md" })
    }

    // MARK: Pipelines

    func testSamplePipelinesHaveTasksAndDependencies() async throws {
        let client = HubClient(api: makeHub())
        let jobs = try await client.jobs()
        XCTAssertEqual(jobs.count, 3)
        XCTAssertTrue(jobs.allSatisfy { !$0.tasks.isEmpty })
        XCTAssertTrue(jobs.contains { $0.tasks.contains { !$0.dependencies.isEmpty } })
        XCTAssertEqual(jobs.first { $0.id == "job-demo-signup" }?.status, .inProgress)
        XCTAssertEqual(jobs.first { $0.id == "job-demo-docs" }?.status, .completed)
    }

    func testCreateAndDeletePipelineWorkInMemory() async throws {
        let hub = makeHub()
        let client = HubClient(api: hub)
        let draftBody = CreateJobBody(
            id: nil, title: "Check the docs", description: "Sample",
            tasks: [
                CreateJobBody.TaskBody(id: "read", title: "Read", description: "", assignedAgent: "codex",
                                       dependencies: []),
                CreateJobBody.TaskBody(id: "write", title: "Write", description: "", assignedAgent: "claude_code",
                                       dependencies: ["read"]),
            ])
        let created = try await client.createJob(draftBody)
        XCTAssertEqual(created.title, "Check the docs")
        XCTAssertEqual(created.status, .pending)
        XCTAssertEqual(created.tasks.first { $0.id == "read" }?.status, .ready)
        XCTAssertEqual(created.tasks.first { $0.id == "write" }?.status, .pending)
        let listed = try await client.jobs()
        XCTAssertEqual(listed.count, 4)
        XCTAssertTrue(listed.contains { $0.id == created.id })

        try await client.deleteJob(id: created.id)
        let after = try await client.jobs()
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(after.contains { $0.id == created.id })
    }

    func testCreatePipelineRefusalsCarryAReason() async throws {
        let client = HubClient(api: makeHub())
        func create(title: String, tasks: [CreateJobBody.TaskBody], id: String? = nil) async -> HubRejection? {
            do {
                _ = try await client.createJob(CreateJobBody(id: id, title: title, description: "", tasks: tasks))
                return nil
            } catch {
                return error as? HubRejection
            }
        }
        let task = CreateJobBody.TaskBody(id: "a", title: "A", description: "", assignedAgent: "codex",
                                          dependencies: [])
        let noTitle = await create(title: " ", tasks: [task])
        XCTAssertEqual(noTitle?.status, 422)
        let noTasks = await create(title: "T", tasks: [])
        XCTAssertEqual(noTasks?.status, 422)
        let missing = CreateJobBody.TaskBody(id: "b", title: "B", description: "", assignedAgent: "codex",
                                             dependencies: ["nope"])
        let badDependency = await create(title: "T", tasks: [missing])
        XCTAssertEqual(badDependency?.status, 422)
        XCTAssertNotNil(badDependency?.detail)
        let duplicate = await create(title: "T", tasks: [task], id: "job-demo-signup")
        XCTAssertEqual(duplicate?.status, 409)
    }

    func testDeletingAnUnknownPipelineIsRefused() async throws {
        let client = HubClient(api: makeHub())
        do {
            try await client.deleteJob(id: "does-not-exist")
            XCTFail("an unknown pipeline must be refused")
        } catch let rejection as HubRejection {
            XCTAssertEqual(rejection.status, 404)
        }
    }

    func testRevisionAndFailChangeTheTask() async throws {
        let hub = makeHub()
        let client = HubClient(api: hub)
        try await client.requestRevision(taskId: "review-edges", feedback: "Please add an example.")
        try await client.failTask(taskId: "update-docs", reason: "Not needed in the demo.")
        let jobs = try await client.jobs()
        let tasks = jobs.flatMap { $0.tasks }
        XCTAssertEqual(tasks.first { $0.id == "review-edges" }?.status, .revisionRequested)
        XCTAssertEqual(tasks.first { $0.id == "update-docs" }?.status, .failed)
        XCTAssertEqual(jobs.first { $0.id == "job-demo-signup" }?.status, .failed)
    }

    func testUnknownRouteAnswers404() async throws {
        let response = try await makeHub().send(method: "GET", path: "/api/nothing", body: nil)
        XCTAssertEqual(response.status, 404)
    }

    // MARK: No network, no Keychain

    func testTheDemoHubHasNoNetworkRoute() {
        let client = HubClient(api: makeHub())
        XCTAssertNil(client.baseURL)
    }

    @MainActor
    func testDemoModeInAppModelWritesNothingToTheKeychainAndExitsCleanly() async throws {
        let store = CountingSecretStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(secrets: store, directory: directory)
        XCTAssertFalse(model.isDemo)

        model.startDemo()
        XCTAssertTrue(model.isDemo)
        XCTAssertTrue(model.hubs.isEmpty)
        XCTAssertEqual(model.routeLabel, "Demo")
        XCTAssertTrue(model.connection.isOnline)
        XCTAssertTrue(model.canDispatch)
        XCTAssertTrue(model.canManageJobs)
        XCTAssertTrue(model.canRefreshUsageOnHub)
        XCTAssertTrue(model.canAttachFromComputer)

        try await waitUntil { !model.usage.isEmpty && !model.jobs.isEmpty && !model.sessions.isEmpty
            && model.catalogue.hasNamedModels && !model.consoleLines.isEmpty }
        XCTAssertEqual(model.statusLine, UserMessages.demoStatus)

        let sent = await model.send(agent: "claude_code", prompt: "Say hello")
        XCTAssertTrue(sent)
        try await waitUntil { model.consoleLines.contains { $0.content.contains("Demo reply") } }

        let job = try await model.createPipeline(PipelineDraft.sample(title: "Demo pipeline"))
        XCTAssertTrue(model.jobs.contains { $0.id == job.id })
        try await model.deletePipeline(id: job.id)
        XCTAssertFalse(model.jobs.contains { $0.id == job.id })

        let files = try await model.hubFiles()
        XCTAssertEqual(files, DemoData.files)

        model.exitDemo()
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.consoleLines.isEmpty)
        XCTAssertTrue(model.usage.isEmpty)
        XCTAssertEqual(model.routeLabel, "Offline")
        XCTAssertEqual(store.writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        model.stop()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("the condition never became true")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private extension PipelineDraft {
    /// A valid draft with one task, for tests.
    static func sample(title: String) -> PipelineDraft {
        var draft = PipelineDraft()
        draft.title = title
        draft.tasks[0].title = "Only task"
        return draft
    }
}
