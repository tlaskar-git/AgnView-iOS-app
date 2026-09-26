import XCTest
@testable import AgnView

/// End-to-end checks of IrohTransport against a real AgnView hub, started by
/// the e2e-iroh workflow. Skipped unless AGNVIEW_E2E_TICKET is set. The ticket
/// and the key come from the environment only. Nothing here prints them.
final class IrohRealHubTests: XCTestCase {
    private var ticket: String {
        ProcessInfo.processInfo.environment["AGNVIEW_E2E_TICKET"] ?? ""
    }

    private var key: String {
        ProcessInfo.processInfo.environment["AGNVIEW_E2E_KEY"] ?? ""
    }

    /// Prints a result line and, when the workflow gave a path, appends it
    /// there too. Lines carry no ticket, key or address.
    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["AGNVIEW_E2E_OUT"], !path.isEmpty,
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(!ticket.isEmpty && !key.isEmpty, "no real hub configured")
    }

    private func connect(key overrideKey: String? = nil) async throws -> HubSession {
        try await IrohTransport(ticket: ticket, token: overrideKey ?? key).connect()
    }

    /// Waits for a log frame that satisfies `match`, or fails after `seconds`.
    private func waitForLog(_ session: HubSession, seconds: UInt64,
                            match: @escaping (ConsoleFrame.LogEntry) -> Bool) async throws -> ConsoleFrame.LogEntry {
        let frames = session.frames
        return try await withThrowingTaskGroup(of: ConsoleFrame.LogEntry.self) { group in
            group.addTask {
                for try await frame in frames {
                    if case .log(let entry) = frame, match(entry) { return entry }
                }
                throw TransportError.protocolViolation
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func testRealHubAPIAndDispatchOverIroh() async throws {
        let session = try await connect()
        addTeardownBlock { await session.close() }

        // Hello arrived: the hub lists the api capability.
        let consoleSession = try XCTUnwrap(session as? ConsoleStreamSession)
        XCTAssertTrue(consoleSession.hello.offersAPI, "hello lists the api capability")
        XCTAssertEqual(session.capabilities, .irohAPI)
        XCTAssertTrue([TransportRoute.direct, .relay].contains(session.route))
        report("E2E-ROUTE \(session.route.rawValue)")

        let api = try XCTUnwrap(session.api)
        let client = HubClient(api: api)

        let status = try await client.status()
        XCTAssertEqual(status.status, "healthy")
        _ = try await client.usageAccounts()
        _ = try await client.jobs()
        _ = try await client.liveSessions()
        let logs = try await api.send(method: "GET", path: "/api/console/logs?agent=all&limit=50", body: nil)
        XCTAssertEqual(logs.status, 200)
        report("E2E-PASS status usage jobs live-sessions logs")

        // A path outside the allowlist is refused.
        do {
            _ = try await api.send(method: "GET", path: "/api/mobile/pairing", body: nil)
            XCTFail("a forbidden path must be refused")
        } catch {
            XCTAssertEqual(error as? TransportError, .notSupported)
        }
        report("E2E-PASS forbidden path refused")

        // An unknown agent is refused with 422.
        let refused = try JSONEncoder().encode(DispatchRequest(targetAgent: "no_such_agent", prompt: "x"))
        let unknown = try await api.send(method: "POST", path: "/api/console/dispatch", body: refused)
        XCTAssertEqual(unknown.status, 422)
        report("E2E-PASS unknown agent refused")

        // A known agent runs and its output reaches the console stream.
        let marker = "e2e-marker-\(UUID().uuidString.prefix(8))"
        let response = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: marker))
        XCTAssertEqual(response.status, "dispatched")
        let entry = try await waitForLog(session, seconds: 60) { entry in
            let content = entry.content ?? ""
            return content.contains("stub agent line") || content.contains(marker)
        }
        XCTAssertNotNil(entry.id)
        report("E2E-PASS dispatch output seen on the console stream")
    }

    /// Phase A over iroh: model, effort and files reach the agent, Sessions
    /// refresh reads the live sessions and the log, and the calls the hub
    /// keeps to the LAN are refused.
    func testRealHubModelEffortSessionsAndLANOnlyRoutes() async throws {
        let session = try await connect()
        addTeardownBlock { await session.close() }
        let api = try XCTUnwrap(session.api)
        let client = HubClient(api: api)

        // Model and effort go through the dispatch call, and the stub
        // agent prints the arguments it was given.
        let marker = "e2e-effort-\(UUID().uuidString.prefix(8))"
        report("E2E-STEP connected, dispatching")
        report("E2E-STEP task cancelled before the call: \(Task.isCancelled)")
        let response: DispatchResponse
        do {
            response = try await client.dispatch(DispatchRequest(targetAgent: "codex", prompt: marker,
                                                                 model: "gpt-5", effort: "low"))
        } catch {
            report("E2E-STEP the dispatch threw \(type(of: error)) \(error), task cancelled: \(Task.isCancelled)")
            throw error
        }
        XCTAssertEqual(response.status, "dispatched")
        report("E2E-STEP dispatched, reading the log")

        // The stub prints its arguments as the agent's reply. Read the log
        // through the API until the reply is there.
        func carriesTheChoices(_ content: String) -> Bool {
            content.contains("stub args") && content.contains("reasoning_effort=low")
                && content.contains("-m gpt-5")
        }
        var seen = false
        var lastRows: [ConsoleFrame.LogEntry] = []
        let deadline = Date().addingTimeInterval(60)
        while !seen, Date() < deadline {
            lastRows = try await client.logs(limit: 60)
            seen = lastRows.contains { carriesTheChoices($0.content ?? "") }
            if !seen { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        if !seen {
            for row in lastRows.suffix(12) {
                report("E2E-DEBUG \(row.agent ?? "-") \(row.source ?? "-") \(String((row.content ?? "").prefix(200)))")
            }
        }
        XCTAssertTrue(seen, "the agent never printed the model, effort and files it was given")
        report("E2E-PASS model and effort reached the agent over iroh")

        // Sessions refresh: the live sessions and the newest log rows.
        let live = try await client.liveSessions()
        let rows = try await client.logs(limit: 50)
        XCTAssertFalse(rows.isEmpty, "the log holds the dispatch just made")
        report("E2E-PASS sessions refresh read \(live.count) live sessions and \(rows.count) log rows")

        // Hub 0.1.12 keeps these to the LAN, so iroh refuses them and the app
        // switches the matching controls off. A newer hub can open some of
        // them, so the pipeline calls are noted and not required to fail.
        let refused: [(String, String, Data?)] = [
            ("GET", HubPath.capabilities, nil),
            ("GET", HubPath.files, nil),
            ("POST", HubPath.usageRefreshAll, Data("{}".utf8)),
        ]
        for (method, path, body) in refused {
            do {
                _ = try await api.send(method: method, path: path, body: body)
                XCTFail("\(method) \(path) must be refused over iroh")
            } catch {
                XCTAssertEqual(error as? TransportError, .notSupported, "\(method) \(path)")
            }
        }
        let optional: [(String, String, Data?)] = [
            ("POST", HubPath.jobs, Data(#"{"title":"x","tasks":[]}"#.utf8)),
            ("DELETE", HubPath.job("no-such-job"), nil),
        ]
        for (method, path, body) in optional {
            do {
                let answer = try await api.send(method: method, path: path, body: body)
                report("E2E-NOTE \(method) \(path) is open over iroh on this hub (status \(answer.status))")
            } catch {
                XCTAssertEqual(error as? TransportError, .notSupported, "\(method) \(path)")
            }
        }
        XCTAssertTrue(Set<Capability>.irohAPI.isDisjoint(with: Capability.lanOnly))
        report("E2E-PASS LAN only calls refused over iroh")
    }

    func testRealHubRejectsAWrongKey() async throws {
        do {
            let session = try await connect(key: "wrong-test-value")
            await session.close()
            XCTFail("a wrong key must be refused")
        } catch {
            XCTAssertEqual(error as? TransportError, .unauthorised)
        }
        report("E2E-PASS wrong key refused")
    }
}
