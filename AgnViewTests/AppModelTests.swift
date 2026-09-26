import XCTest
@testable import AgnView

@MainActor
final class AppModelTests: XCTestCase {
    private var dir: URL!
    private var secrets: InMemorySecretStore!
    private var clock: FakeClock!
    private var nowBox: DateBox!
    private var afterIds: LockedList<Int?>!
    private var models: [AppModel] = []

    private let lanCaps: Set<Capability> = .lan
    private let irohCaps: Set<Capability> = .iroh

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-\(UUID().uuidString)", isDirectory: true)
        secrets = InMemorySecretStore()
        clock = FakeClock()
        nowBox = DateBox(Date(timeIntervalSince1970: 1_800_000_000))
        afterIds = LockedList<Int?>()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            switch request.url.path {
            case "/api/mobile/status": return .response(200, Data(SampleJSON.status.utf8))
            case "/api/usage/accounts": return .response(200, Data(SampleJSON.usage.utf8))
            case "/api/jobs": return .response(200, Data(SampleJSON.jobs.utf8))
            case "/api/console/live-sessions": return .response(200, Data(SampleJSON.liveSessions.utf8))
            case "/api/console/dispatch": return .response(200, Data(SampleJSON.dispatch.utf8))
            default: return .response(404, Data())
            }
        }
    }

    override func tearDown() async throws {
        for model in models { model.stop() }
        models = []
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func makeModel(lan: TransportScript, iroh: TransportScript? = nil) -> AppModel {
        let lanTransport = lan.transport()
        let irohTransport = (iroh ?? TransportScript([TransportScript.fail(.unreachable)])).transport()
        let urlSession = StubURLProtocol.session()
        let ids = afterIds!
        let box = nowBox!
        let model = AppModel(
            secrets: secrets, directory: dir, clock: clock, now: { box.date },
            makeLadder: { endpoint, clock, afterId in
                ids.append(afterId)
                return ConnectionLadder(endpoint: endpoint, clock: clock,
                                        makeLAN: { _ in lanTransport },
                                        makeIroh: { _, _ in irohTransport })
            },
            makeClient: { endpoint in
                HubClient(baseURL: LANTransport.baseURL(host: endpoint.lanHost, port: endpoint.lanPort),
                          token: endpoint.token, session: urlSession)
            })
        models.append(model)
        return model
    }

    private func pairingURL(idByte: UInt8 = 0x42, name: String = "Test Hub",
                            lan: String = "192.0.2.10:18845") -> URL {
        var components = URLComponents()
        components.scheme = "agnview"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "lan", value: lan),
            URLQueryItem(name: "fp", value: String(repeating: "a", count: 64)),
            URLQueryItem(name: "id", value: Base64URL.encode(Data(repeating: idByte, count: 16))),
            URLQueryItem(name: "k", value: Base64URL.encode(Data(repeating: 0x41, count: 32))),
            URLQueryItem(name: "iroh", value: "endpointexampleticketnotreal"),
        ]
        return components.url!
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func waitForState(_ model: AppModel, _ state: ConnectionState,
                              file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(state)", file: file, line: line) { model.connection == state }
    }

    /// Waits for offline(retryIn: delay) after `ladderRuns` connection attempts,
    /// then lets the fake clock pass the delay.
    private func passBackoff(_ model: AppModel, _ delay: Duration, ladderRuns: Int,
                             file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("attempt \(ladderRuns)", file: file, line: line) {
            self.afterIds.values.count == ladderRuns && model.connection == .offline(retryIn: delay)
        }
        await clock.waitForSleepers(1)
        clock.advance(by: delay)
    }

    private func pairAndConnect(_ model: AppModel, lanSession: ScriptedSession) async {
        model.pair(url: pairingURL())
        await waitForState(model, .online(.lan, lanCaps))
    }

    // MARK: Pairing and connect

    func testPairingThenOnlineOverLAN() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        XCTAssertTrue(model.hubs.isEmpty)
        model.pair(text: pairingURL().absoluteString)
        XCTAssertEqual(model.pairingResult, .success("Test Hub"))
        XCTAssertEqual(model.hubs.count, 1)
        await waitForState(model, .online(.lan, lanCaps))
        XCTAssertEqual(model.route, .lan)
        XCTAssertFalse(model.relayOnly)
        XCTAssertNil(model.lanUnavailableReason)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.activeHub?.everConnected, true)
        await waitUntil("LAN data") {
            model.usageSnapshot != nil && !model.jobs.isEmpty && !model.sessions.isEmpty
                && model.statusLine.contains("healthy")
        }
        XCTAssertEqual(model.usage.count, 2)
        XCTAssertEqual(model.usageSnapshot?.takenAt, nowBox.date)
        XCTAssertEqual(model.jobs.first?.id, "job-1")
        XCTAssertEqual(model.sessions.first?.id, "session-1")
        XCTAssertEqual(model.sessions.first?.fromLog, false)
        XCTAssertFalse(model.sessionsAreDerived)
        XCTAssertNil(model.usageNotice)
        XCTAssertNil(model.jobsNotice)
        XCTAssertNil(model.sessionsNotice)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.headers["X-AgnView-Token"] != nil })
    }

    func testPairingFailures() {
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]))
        model.pair(text: "not a pairing link")
        if case .failure = model.pairingResult {} else { XCTFail("expected failure") }
        model.pair(url: URL(string: "agnview://other?v=1")!)
        XCTAssertEqual(model.pairingResult, .failure(.wrongHost))
        XCTAssertTrue(model.hubs.isEmpty)
    }

    // MARK: Error states

    func testAuthFailedWhenNeverConnected() async {
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unauthorised)]))
        model.pair(url: pairingURL())
        await waitForState(model, .authFailed)
        XCTAssertEqual(model.statusMessage, UserMessages.authFailed)
        XCTAssertEqual(model.activeHub?.everConnected, false)
        XCTAssertTrue(model.capabilities.isEmpty)
    }

    func testAuthFailedFromIrohUnauthorisedBeforeAnyConnect() async {
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.fail(.unauthorised)]))
        model.pair(url: pairingURL())
        await waitForState(model, .authFailed)
    }

    func testKeyRevokedAfterAConnectedSession() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        session.finish(TransportError.unauthorised)
        await waitForState(model, .keyRevoked)
        XCTAssertEqual(model.statusMessage, UserMessages.keyRevoked)
        XCTAssertEqual(model.activeHub?.everConnected, true)
    }

    func testIrohUnauthorisedFrameAfterConnectIsKeyRevoked() async {
        let session = ScriptedSession(route: .direct)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.direct, irohCaps))
        session.send(.error(detail: ConsoleFrame.unauthorisedDetail))
        await waitForState(model, .keyRevoked)
    }

    func testRateLimitGoesOfflineWithRetryTimer() async {
        let model = makeModel(lan: TransportScript([TransportScript.fail(.rateLimited)]))
        model.pair(url: pairingURL())
        await waitForState(model, .offline(retryIn: .seconds(1)))
        XCTAssertEqual(model.statusMessage, UserMessages.offlineHub)
    }

    func testRepairAfterKeyRevokedResetsEverConnected() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session),
                                                    TransportScript.fresh(.lan)]))
        await pairAndConnect(model, lanSession: session)
        session.finish(TransportError.unauthorised)
        await waitForState(model, .keyRevoked)
        model.pair(url: pairingURL())
        await waitForState(model, .online(.lan, lanCaps))
        XCTAssertEqual(model.hubs.count, 1)
        XCTAssertEqual(model.pairingResult, .success("Test Hub"))
    }

    func testOfflineBackoffSequence() async {
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]))
        model.pair(url: pairingURL())
        let expected: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15)]
        for (index, delay) in expected.enumerated() {
            await passBackoff(model, delay, ladderRuns: index + 1)
        }
        XCTAssertEqual(model.statusMessage, UserMessages.offlineHub)
    }

    func testWatchdogDropReconnectsAndResumesAfterLastId() async {
        let first = ScriptedSession(route: .lan)
        let second = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(first),
                                                    TransportScript.session(second)]))
        await pairAndConnect(model, lanSession: first)
        first.sendLog(id: 1)
        first.sendLog(id: 2)
        first.sendLog(id: 3)
        await waitUntil("three lines") { model.consoleLines.count == 3 }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(45))
        await passBackoff(model, .seconds(1), ladderRuns: 1)
        await waitForState(model, .online(.lan, lanCaps))
        XCTAssertEqual(afterIds.values, [nil, 3])
        second.sendLog(id: 3)
        second.sendLog(id: 4)
        await waitUntil("line 4") { model.consoleLines.last?.id == 4 }
        XCTAssertEqual(model.consoleLines.map(\.id), [1, 2, 3, 4])
    }

    // MARK: Capability gating

    func testDispatchOffLANThrowsExactMessage() async {
        let session = ScriptedSession(route: .direct)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.direct, irohCaps))
        XCTAssertFalse(model.canDispatch)
        do {
            _ = try await model.dispatch(agent: "claude_code", prompt: "Example prompt")
            XCTFail("dispatch must throw off the LAN")
        } catch let error as DispatchUnavailable {
            XCTAssertEqual(error.message, "Your hub does not support remote access yet. Update AgnView on your computer to 0.1.12 or later.")
            XCTAssertEqual(error.localizedDescription, error.message)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.path == "/api/console/dispatch" })
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.jobsNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.sessionsNotice, "Showing sessions seen in the log stream")
        XCTAssertEqual(model.statusMessage, UserMessages.notOnSameNetworkBanner)
        await model.refreshUsage()
        await model.refreshJobs()
        XCTAssertNil(model.usageSnapshot)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.path == "/api/usage/accounts" })
    }

    func testDispatchOverLANSendsRequest() async throws {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        XCTAssertTrue(model.canDispatch)
        let response = try await model.dispatch(agent: "codex", prompt: "Example prompt")
        XCTAssertEqual(response.status, "dispatched")
        let request = try XCTUnwrap(StubURLProtocol.requests.last { $0.url.path == "/api/console/dispatch" })
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["agent"] as? String, "codex")
        XCTAssertEqual(json["prompt"] as? String, "Example prompt")
    }

    // MARK: Panel isolation

    private func answering(garbage path: String, status: Int = 200) {
        let good = StubURLProtocol.handler
        StubURLProtocol.handler = { request in
            if request.url.path == path { return .response(status, Data("<<not json>>".utf8)) }
            return good?(request) ?? .response(404, Data())
        }
    }

    func testUsageDecodeFailureFailsOnlyTheUsagePanel() async {
        answering(garbage: "/api/usage/accounts")
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await model.refreshUsage()
        await model.refreshJobs()
        await model.refreshSessions()
        XCTAssertEqual(model.usageState, .failed("Usage could not be read. Tap Retry."))
        XCTAssertEqual(model.connection, .online(.lan, lanCaps))
        XCTAssertNotNil(model.jobsState.value)
        XCTAssertNotNil(model.sessionsState.value)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertNil(model.notice)
    }

    func testServerErrorFailsThePanelNotTheConnection() async {
        answering(garbage: "/api/jobs", status: 500)
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await model.refreshJobs()
        XCTAssertEqual(model.jobsState, .failed("Pipelines could not be read. Tap Retry."))
        XCTAssertEqual(model.connection, .online(.lan, lanCaps))
    }

    func testRetryRecoversAFailedPanel() async {
        answering(garbage: "/api/usage/accounts")
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await model.refreshUsage()
        XCTAssertNotNil(model.usageState.failureMessage)
        StubURLProtocol.handler = { request in
            request.url.path == "/api/usage/accounts"
                ? .response(200, Data(SampleJSON.usage.utf8)) : .response(404, Data())
        }
        await model.retryUsage()
        XCTAssertEqual(model.usageState.value?.accounts.count, 2)
        XCTAssertNil(model.usageState.failureMessage)
    }

    func testSendRecordsTheReplyAndAFailureKeepsItInline() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        XCTAssertNil(model.dispatchState)
        let ok = await model.send(agent: "codex", prompt: "Example prompt")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.dispatchState?.value?.status, "dispatched")
        XCTAssertEqual(model.dispatchState?.value?.sessionId, "sess-1")
        answering(garbage: "/api/console/dispatch")
        let failed = await model.send(agent: "codex", prompt: "Example prompt")
        XCTAssertFalse(failed)
        XCTAssertNotNil(model.dispatchState?.failureMessage)
        XCTAssertEqual(model.connection, .online(.lan, lanCaps))
    }

    func testStatusLineNamesTheHubAndLeavesTheTransportToThePill() {
        let real = MobileStatus(status: "healthy", service: "AgnView", version: "",
                                transportLabel: "Loopback only", resolvedTransport: "offline")
        XCTAssertEqual(AppModel.statusText(real, hubName: "Office PC"), "Office PC is healthy")
        XCTAssertFalse(AppModel.statusText(real, hubName: "Office PC").contains("Loopback"))
        XCTAssertEqual(AppModel.statusText(MobileStatus(status: "degraded", service: "x", version: ""),
                                           hubName: "Office PC"), "Office PC is degraded")
        XCTAssertEqual(AppModel.statusText(real, hubName: "  "), "The hub is healthy")
    }

    func testDispatchTransportFailureIsWrapped() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        StubURLProtocol.handler = { _ in .response(429, Data()) }
        do {
            _ = try await model.dispatch(agent: "codex", prompt: "p")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HubError, .transport(.rateLimited))
        }
    }

    func testRelayOnlyBanner() async {
        let session = ScriptedSession(route: .direct)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL(lan: "127.0.0.1:18845"))
        await waitForState(model, .online(.direct, irohCaps))
        XCTAssertTrue(model.relayOnly)
        XCTAssertEqual(model.lanUnavailableReason, .pairedWithoutLAN)
        XCTAssertEqual(model.statusMessage,
                       "This pairing has no local network address. In AgnView, turn on Allow phones on my network, then scan the pairing QR code again.")
        XCTAssertEqual(model.dispatchNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.jobsNotice, UserMessages.hubNeedsUpdate)
    }

    func testNotOnSameNetworkReason() async {
        let session = ScriptedSession(route: .direct)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.direct, irohCaps))
        XCTAssertFalse(model.relayOnly)
        XCTAssertEqual(model.lanUnavailableReason, .notOnSameNetwork)
        XCTAssertEqual(model.statusMessage,
                       "Not on the same Wi-Fi as your computer. Console works over iroh. Prompts, Usage and Pipelines need the same Wi-Fi.")
        XCTAssertEqual(model.dispatchNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.jobsNotice, UserMessages.hubNeedsUpdate)
    }

    func testMessageSelectionByReason() {
        XCTAssertEqual(UserMessages.lanBanner(.pairedWithoutLAN), UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(UserMessages.lanBanner(.notOnSameNetwork), UserMessages.notOnSameNetworkBanner)
        XCTAssertEqual(UserMessages.hubNeedsUpdate,
                       "Your hub does not support remote access yet. Update AgnView on your computer to 0.1.12 or later.")
    }

    // MARK: Remote API over iroh

    func testIrohSessionWithAPIHasFullCapabilitiesAndNoLANMessages() async throws {
        let api = FakeAPITransport()
        api.route("GET", "/api/mobile/status", 200, SampleJSON.status)
        api.route("GET", "/api/usage/accounts", 200, SampleJSON.usage)
        api.route("GET", "/api/jobs", 200, SampleJSON.jobs)
        api.route("GET", "/api/console/live-sessions", 200, SampleJSON.liveSessions)
        api.route("POST", "/api/console/dispatch", 200, SampleJSON.dispatch)
        let session = ScriptedSession(route: .direct, capabilities: .irohAPI, api: api)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.direct, .irohAPI))
        XCTAssertTrue(model.canDispatch)
        XCTAssertTrue(model.usageIsLive)
        XCTAssertTrue(model.jobsAreLive)
        XCTAssertFalse(model.sessionsAreDerived)
        XCTAssertNil(model.lanUnavailableReason)
        XCTAssertNil(model.statusMessage)
        XCTAssertNil(model.usageNotice)
        XCTAssertNil(model.jobsNotice)
        XCTAssertNil(model.dispatchNotice)
        await waitUntil("usage over iroh") { model.usageSnapshot != nil }
        let response = try await model.dispatch(agent: "codex", prompt: "Example prompt")
        XCTAssertEqual(response.status, "dispatched")
        XCTAssertTrue(api.calls.contains { $0.method == "POST" && $0.path == "/api/console/dispatch" })
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no LAN request when iroh carries the API")
    }

    func testIrohSessionWithoutAPIKeepsConsoleOnlyAndShowsUpdateMessage() async {
        let session = ScriptedSession(route: .relay)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.relay, .iroh))
        XCTAssertEqual(model.capabilities, [.consoleStream])
        XCTAssertEqual(model.dispatchNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.jobsNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.sessionsNotice, UserMessages.sessionsFromLog)
    }

    // MARK: Console buffer

    func testRingBufferKeepsNewest2000AndDedupes() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        session.sendLog(id: 1)
        session.sendLog(id: 1)
        session.sendLog(id: 2)
        await waitUntil("two lines") { model.consoleLines.count == 2 }
        for id in 3...2100 { session.sendLog(id: id) }
        session.sendLog(id: 2100)
        session.sendLog(id: 2050)
        await waitUntil("last line") { model.consoleLines.last?.id == 2100 }
        // Let the duplicates pass through.
        session.sendLog(id: 2101)
        await waitUntil("line 2101") { model.consoleLines.last?.id == 2101 }
        XCTAssertEqual(model.consoleLines.count, AppModel.ringCapacity)
        XCTAssertEqual(model.consoleLines.first?.id, 102)
        XCTAssertEqual(Set(model.consoleLines.map(\.id)).count, AppModel.ringCapacity)
    }

    func testAgentFilter() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        session.sendLog(id: 1, agent: "claude_code")
        session.sendLog(id: 2, agent: "codex")
        session.sendLog(id: 3, agent: "claude_code")
        await waitUntil("three lines") { model.consoleLines.count == 3 }
        model.setAgentFilter("codex")
        XCTAssertEqual(model.consoleLines.map(\.id), [2])
        session.sendLog(id: 4, agent: "codex")
        session.sendLog(id: 5, agent: "claude_code")
        session.sendLog(id: 6, agent: "codex")
        await waitUntil("line 6") { model.consoleLines.map(\.id) == [2, 4, 6] }
        model.setAgentFilter(nil)
        XCTAssertEqual(model.consoleLines.count, 6)
        XCTAssertNil(model.agentFilter)
    }

    func testSessionsDerivedFromLogWhenCapabilityMissing() async {
        let session = ScriptedSession(route: .relay)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.relay, irohCaps))
        XCTAssertTrue(model.sessionsAreDerived)
        session.sendLog(id: 1, agent: "claude_code", sessionId: "s-1", timestamp: "2026-01-01T00:00:01Z")
        session.sendLog(id: 2, agent: "user", sessionId: "s-1", timestamp: "2026-01-01T00:00:02Z")
        session.sendLog(id: 3, agent: "codex", sessionId: "s-2", timestamp: "2026-01-01T00:00:03Z")
        session.sendLog(id: 4, agent: "system", sessionId: nil)
        await waitUntil("derived sessions") { model.consoleLines.count == 4 && model.sessions.count == 2 }
        XCTAssertEqual(model.sessions.map(\.id), ["s-2", "s-1"])
        XCTAssertEqual(model.sessions[1].agent, "claude_code")
        XCTAssertEqual(model.sessions[1].lineCount, 2)
        XCTAssertTrue(model.sessions.allSatisfy(\.fromLog))
        XCTAssertEqual(model.sessionsNotice, UserMessages.sessionsFromLog)
    }

    // MARK: Usage snapshot

    func testUsageSnapshotKeptWithItsTimeWhenMovingFromLANToIroh() async {
        let lanSession = ScriptedSession(route: .lan)
        let irohSession = ScriptedSession(route: .direct)
        let model = makeModel(lan: TransportScript([TransportScript.session(lanSession),
                                                    TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(irohSession)]))
        await pairAndConnect(model, lanSession: lanSession)
        await waitUntil("usage") { model.usageSnapshot != nil }
        let taken = model.usageSnapshot?.takenAt
        XCTAssertEqual(taken, nowBox.date)
        XCTAssertTrue(model.usageIsLive)
        nowBox.date = nowBox.date.addingTimeInterval(600)
        lanSession.finish()
        await passBackoff(model, .seconds(1), ladderRuns: 1)
        await waitForState(model, .online(.direct, irohCaps))
        XCTAssertEqual(model.usageSnapshot?.takenAt, taken)
        XCTAssertEqual(model.usage.count, 2)
        XCTAssertFalse(model.usageIsLive)
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        await model.refreshUsage()
        XCTAssertEqual(model.usageSnapshot?.takenAt, taken)
    }

    // MARK: Hubs

    func testRemoveDeletesKeyAndPromotesNextHub() async {
        let model = makeModel(lan: TransportScript([TransportScript.fresh(.lan)]))
        model.pair(url: pairingURL(idByte: 0x01, name: "Hub A"))
        model.pair(url: pairingURL(idByte: 0x02, name: "Hub B"))
        let idA = Base64URL.encode(Data(repeating: 0x01, count: 16))
        let idB = Base64URL.encode(Data(repeating: 0x02, count: 16))
        XCTAssertEqual(model.hubs.map(\.id), [idA, idB])
        XCTAssertEqual(model.activeHub?.id, idB)
        await waitForState(model, .online(.lan, lanCaps))
        model.remove(idB)
        XCTAssertEqual(model.hubs.map(\.id), [idA])
        XCTAssertEqual(model.activeHub?.id, idA)
        XCTAssertNil(try secrets.get(account: idB))
        XCTAssertNotNil(try secrets.get(account: idA))
        XCTAssertEqual(model.notice, "Removed from this phone. The key stays valid on the hub until you regenerate it there.")
        XCTAssertTrue(model.consoleLines.isEmpty)
        await waitForState(model, .online(.lan, lanCaps))
        XCTAssertEqual(model.activeHub?.name, "Hub A")
    }

    func testRemoveLastHubGoesOfflineWithoutRetry() async {
        let model = makeModel(lan: TransportScript([TransportScript.fresh(.lan)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.lan, lanCaps))
        let id = model.hubs[0].id
        model.remove(id)
        XCTAssertTrue(model.hubs.isEmpty)
        XCTAssertNil(model.activeHub)
        XCTAssertEqual(model.connection, .offline(retryIn: nil))
        XCTAssertNil(model.statusMessage)
        XCTAssertNil(try secrets.get(account: id))
    }

    func testSwitchToResetsDataAndReconnects() async {
        let model = makeModel(lan: TransportScript([TransportScript.fresh(.lan)]))
        model.pair(url: pairingURL(idByte: 0x01, name: "Hub A"))
        model.pair(url: pairingURL(idByte: 0x02, name: "Hub B"))
        await waitForState(model, .online(.lan, lanCaps))
        await waitUntil("usage") { model.usageSnapshot != nil }
        let idA = model.hubs[0].id
        model.switchTo(idA)
        XCTAssertEqual(model.activeHub?.id, idA)
        XCTAssertNil(model.usageSnapshot)
        XCTAssertTrue(model.consoleLines.isEmpty)
        await waitForState(model, .online(.lan, lanCaps))
    }

    // MARK: Forced states (debug builds only)

    #if DEBUG
    private func forced(_ name: String) -> AppModel {
        let box = nowBox!
        let model = AppModel(secrets: InMemorySecretStore(), directory: dir, clock: clock,
                             now: { box.date })
        models.append(model)
        model.debugForcedState = name
        model.start()
        return model
    }

    func testForcedOffline() {
        let model = forced("offline")
        XCTAssertEqual(model.connection, .offline(retryIn: nil))
        XCTAssertEqual(model.statusMessage, UserMessages.offlineHub)
        XCTAssertEqual(model.route, .offline)
        XCTAssertEqual(model.hubs.count, 1)
    }

    func testForcedAuthFailedAndKeyRevoked() {
        XCTAssertEqual(forced("authFailed").connection, .authFailed)
        XCTAssertEqual(forced("keyRevoked").statusMessage, UserMessages.keyRevoked)
    }

    func testForcedRelayOnly() {
        let model = forced("relayOnly")
        XCTAssertEqual(model.connection, .online(.direct, irohCaps))
        XCTAssertTrue(model.relayOnly)
        XCTAssertEqual(model.lanUnavailableReason, .pairedWithoutLAN)
        XCTAssertEqual(model.statusMessage, UserMessages.pairedWithoutLANBanner)
        XCTAssertFalse(model.canDispatch)
    }

    func testForcedIroh() {
        let model = forced("iroh")
        XCTAssertEqual(model.connection, .online(.direct, irohCaps))
        XCTAssertFalse(model.relayOnly)
        XCTAssertEqual(model.lanUnavailableReason, .notOnSameNetwork)
        XCTAssertEqual(model.statusMessage, UserMessages.notOnSameNetworkBanner)
        XCTAssertEqual(model.consoleLines.count, 4)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(model.sessionsAreDerived)
        XCTAssertEqual(model.usage.count, 1)
        XCTAssertEqual(model.usageNotice, UserMessages.hubNeedsUpdate)
        XCTAssertEqual(model.usageSnapshot?.takenAt, nowBox.date.addingTimeInterval(-300))
    }

    func testForcedIrohJobs() {
        let model = forced("irohJobs")
        XCTAssertEqual(model.connection, .online(.relay, .irohJobs))
        XCTAssertTrue(model.canManageJobs)
        XCTAssertNil(model.pipelineCreateNotice)
        XCTAssertNil(model.jobsNotice)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(model.catalogueOrigin, .stored)
        XCTAssertGreaterThan(model.catalogue.modelOptions(for: "codex").count, 1)
        XCTAssertNil(model.modelMenuNote(for: "claude_code"))
    }

    func testUnknownForcedStateRunsNormally() async {
        let model = forced("not-a-state")
        XCTAssertEqual(model.connection, .offline(retryIn: nil))
        XCTAssertTrue(model.hubs.isEmpty)
    }
    #endif

    // MARK: Phase A

    /// Answers some requests itself and leaves the rest to the default stubs.
    private func stub(_ answer: @escaping (RecordedRequest) -> StubURLProtocol.Answer?) {
        let good = StubURLProtocol.handler
        StubURLProtocol.handler = { request in answer(request) ?? good?(request) ?? .response(404, Data()) }
    }

    /// An iroh session with the mobile API. `.irohAPI` stands for hub 0.1.12,
    /// `.irohJobs` for hub 0.1.13 or later.
    private func irohAPIModel(_ api: FakeAPITransport, caps: Set<Capability> = .irohAPI) async -> AppModel {
        api.route("GET", "/api/mobile/status", 200, SampleJSON.status)
        api.route("GET", "/api/usage/accounts", 200, SampleJSON.usage)
        api.route("GET", "/api/jobs", 200, SampleJSON.jobs)
        api.route("GET", "/api/console/live-sessions", 200, SampleJSON.liveSessions)
        api.route("POST", "/api/console/dispatch", 200, SampleJSON.dispatch)
        let session = ScriptedSession(route: .direct, capabilities: caps, api: api)
        let model = makeModel(lan: TransportScript([TransportScript.fail(.unreachable)]),
                              iroh: TransportScript([TransportScript.session(session)]))
        model.pair(url: pairingURL())
        await waitForState(model, .online(.direct, caps))
        return model
    }

    private func draft() -> PipelineDraft {
        var draft = PipelineDraft(idSeed: "ab12")
        draft.title = "Example pipeline"
        draft.tasks[0].title = "Build"
        return draft
    }

    func testLANSessionCanCreateAttachAndRefreshUsageOnTheHub() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        XCTAssertTrue(model.canManageJobs)
        XCTAssertTrue(model.canAttachFromComputer)
        XCTAssertTrue(model.canRefreshUsageOnHub)
        XCTAssertTrue(model.canActOnTasks)
        XCTAssertNil(model.pipelineCreateNotice)
        XCTAssertEqual(model.features, .phaseA)
    }

    func testIrohSessionKeepsTheLANOnlyCallsOff() async {
        let model = await irohAPIModel(FakeAPITransport())
        XCTAssertFalse(model.canManageJobs)
        XCTAssertFalse(model.canAttachFromComputer)
        XCTAssertFalse(model.canRefreshUsageOnHub)
        XCTAssertTrue(model.canActOnTasks, "revision and fail are on the iroh allowlist")
        XCTAssertEqual(model.pipelineCreateNotice, UserMessages.needsSameWiFi)
        do {
            _ = try await model.createPipeline(draft())
            XCTFail("creating a pipeline needs the LAN")
        } catch {
            XCTAssertEqual(error as? HubError, .transport(.notSupported))
        }
        do {
            _ = try await model.hubFiles()
            XCTFail("listing computer files needs the LAN")
        } catch {
            XCTAssertEqual(error as? HubError, .transport(.notSupported))
        }
        await model.refreshCatalogue()
        XCTAssertEqual(model.catalogue, .empty)
        XCTAssertEqual(model.catalogueOrigin, .none)
        XCTAssertEqual(model.catalogue.effortOptions(for: "codex").map { $0.id }, ["", "low", "medium", "high"])
        XCTAssertEqual(model.modelMenuNote(for: "claude_code"), UserMessages.modelsNeedSameWiFi,
                       "a Default-only menu over iroh says why")
    }

    // MARK: Pipelines over iroh on hub 0.1.13 or later

    func testNewerHubCreatesAndDeletesPipelinesOverIroh() async throws {
        let api = FakeAPITransport()
        api.route("POST", "/api/jobs", 200, phaseACreatedJob)
        api.route("DELETE", "/api/jobs/job-new", 200, #"{"message":"deleted"}"#)
        let model = await irohAPIModel(api, caps: .irohJobs)
        XCTAssertTrue(model.canManageJobs)
        XCTAssertNil(model.pipelineCreateNotice, "no Wi-Fi notice on a hub that creates over iroh")
        XCTAssertNil(model.jobsNotice)
        XCTAssertNil(model.lanUnavailableReason)
        XCTAssertFalse(model.canAttachFromComputer, "the file list stays on the LAN")

        let job = try await model.createPipeline(draft())
        XCTAssertEqual(job.id, "job-new")
        let post = try XCTUnwrap(api.calls.lastIndex { $0.method == "POST" && $0.path == "/api/jobs" })
        let body = try XCTUnwrap(api.calls[post].body)
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["title"] as? String, "Example pipeline")
        XCTAssertTrue(api.calls[(post + 1)...].contains { $0.method == "GET" && $0.path == "/api/jobs" },
                      "the list is read again over iroh after the create")

        try await model.deletePipeline(id: "job-new")
        XCTAssertTrue(api.calls.contains { $0.method == "DELETE" && $0.path == "/api/jobs/job-new" })
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.path.hasPrefix("/api/jobs") },
                       "nothing went to the LAN")
        XCTAssertEqual(model.connection, .online(.direct, .irohJobs))
    }

    func testOlderHubStillCreatesPipelinesOnTheLANOnly() async {
        let api = FakeAPITransport()
        let model = await irohAPIModel(api, caps: .irohAPI)
        XCTAssertFalse(model.canManageJobs)
        XCTAssertTrue(model.canActOnTasks)
        XCTAssertNil(model.jobsNotice, "pipelines are still read over iroh")
        XCTAssertEqual(model.pipelineCreateNotice, UserMessages.needsSameWiFi)
        do {
            try await model.deletePipeline(id: "job-1")
            XCTFail("delete needs the LAN on hub 0.1.12")
        } catch {
            XCTAssertEqual(error as? HubError, .transport(.notSupported))
        }
        XCTAssertFalse(api.calls.contains { $0.method == "POST" && $0.path == "/api/jobs" })
        XCTAssertFalse(api.calls.contains { $0.method == "DELETE" })
    }

    // MARK: Model lists kept from the LAN

    private let lanCatalogueJSON = #"{"models":{"claude_code":[{"id":"example-large","name":"Example Large"}],"codex":[{"id":"example-codex","name":"Example Codex"},{"id":"example-mini","name":"Example Mini"}],"antigravity":[{"id":"example-flash","name":"Example Flash"}]},"efforts":["low","high"]}"#

    func testModelListReadOnTheLANIsUsedLaterOverIroh() async throws {
        let json = lanCatalogueJSON
        stub { request in
            request.url.path == "/api/system/capabilities" ? .response(200, Data(json.utf8)) : nil
        }
        let lanSession = ScriptedSession(route: .lan)
        let first = makeModel(lan: TransportScript([TransportScript.session(lanSession)]))
        await pairAndConnect(first, lanSession: lanSession)
        await first.refreshCatalogue()
        XCTAssertEqual(first.catalogueOrigin, .hub)
        XCTAssertEqual(first.catalogue.modelOptions(for: "codex").map { $0.id }, ["", "example-codex", "example-mini"])
        first.stop()

        // Later, away from the Wi-Fi: the same hub over iroh.
        let api = FakeAPITransport()
        let model = await irohAPIModel(api, caps: .irohJobs)
        await waitUntil("stored lists") { model.catalogueOrigin == .stored }
        for agent in ["claude_code", "codex", "antigravity"] {
            XCTAssertGreaterThan(model.catalogue.modelOptions(for: agent).count, 1, agent)
            XCTAssertNil(model.modelMenuNote(for: agent), agent)
        }
        XCTAssertEqual(model.modelMenuNote(for: "deepseek"), UserMessages.noNamedModels)
        XCTAssertFalse(api.calls.contains { $0.path == HubPath.capabilities },
                       "the lists are not asked for over iroh, where the hub refuses them")
        await model.refreshCatalogueIfMissing(for: "codex")
        XCTAssertEqual(model.catalogueOrigin, .stored)
    }

    func testRemovingAHubDropsItsStoredModelList() async throws {
        let json = lanCatalogueJSON
        stub { request in
            request.url.path == "/api/system/capabilities" ? .response(200, Data(json.utf8)) : nil
        }
        let lanSession = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(lanSession)]))
        await pairAndConnect(model, lanSession: lanSession)
        await model.refreshCatalogue()
        let hubId = try XCTUnwrap(model.activeHub?.id)
        XCTAssertNotNil(CatalogueCache(directory: dir).catalogue(for: hubId))
        model.remove(hubId)
        XCTAssertNil(CatalogueCache(directory: dir).catalogue(for: hubId))
    }

    func testAgentChangeReadsTheListAgainWhenItIsMissing() async {
        let lanSession = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(lanSession)]))
        await pairAndConnect(model, lanSession: lanSession)
        await waitUntil("first read") {
            StubURLProtocol.requests.contains { $0.url.path == "/api/system/capabilities" }
        }
        XCTAssertEqual(model.catalogueOrigin, .none, "the first read failed")
        let json = lanCatalogueJSON
        stub { request in
            request.url.path == "/api/system/capabilities" ? .response(200, Data(json.utf8)) : nil
        }
        await model.refreshCatalogueIfMissing(for: "antigravity")
        XCTAssertEqual(model.catalogueOrigin, .hub)
        XCTAssertEqual(model.catalogue.modelOptions(for: "antigravity").map { $0.id }, ["", "example-flash"])
    }

    func testCatalogueLoadsOverLAN() async {
        stub { request in
            request.url.path == "/api/system/capabilities"
                ? .response(200, Data(#"{"models":{"codex":[{"id":"example-codex","name":"Example Codex"}]},"efforts":["low","high"]}"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await model.refreshCatalogue()
        XCTAssertEqual(model.catalogue.modelOptions(for: "codex").map { $0.id }, ["", "example-codex"])
        XCTAssertEqual(model.catalogue.effortOptions(for: "codex").map { $0.id }, ["", "low", "high"])
    }

    func testHubFilesListOverLAN() async throws {
        stub { request in
            request.url.path == "/api/system/files"
                ? .response(200, Data(#"{"files":["a.txt","b/c.txt"],"cwd":"/example"}"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        let files = try await model.hubFiles()
        XCTAssertEqual(files, ["a.txt", "b/c.txt"])
    }

    func testCreatePipelineOverLANPostsThenReadsTheList() async throws {
        stub { request in
            request.url.path == "/api/jobs" && request.method == "POST"
                ? .response(200, Data(phaseACreatedJob.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        let job = try await model.createPipeline(draft())
        XCTAssertEqual(job.id, "job-new")
        let requests = StubURLProtocol.requests
        let post = try XCTUnwrap(requests.lastIndex { $0.url.path == "/api/jobs" && $0.method == "POST" })
        XCTAssertTrue(requests[(post + 1)...].contains { $0.url.path == "/api/jobs" && $0.method == "GET" },
                      "the list is read again after the create")
    }

    func testCreatePipelineRefusalKeepsTheHubReason() async {
        stub { request in
            request.url.path == "/api/jobs" && request.method == "POST"
                ? .response(400, Data(#"{"detail":"Dependency cycle detected involving 'a' and 'b'."}"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        do {
            _ = try await model.createPipeline(draft())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Dependency cycle detected involving 'a' and 'b'.")
            XCTAssertTrue(error is HubRejection)
        }
        XCTAssertEqual(model.connection, .online(.lan, lanCaps), "a refused create leaves the connection alone")
    }

    func testDeletePipelineUsesDeleteOverLAN() async throws {
        stub { request in
            request.url.path == "/api/jobs/job-1" && request.method == "DELETE"
                ? .response(200, Data(#"{"message":"deleted"}"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        try await model.deletePipeline(id: "job-1")
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.method == "DELETE" && $0.url.path == "/api/jobs/job-1" })
    }

    func testRevisionAndFailGoThroughTheAPIOverIroh() async throws {
        let api = FakeAPITransport()
        api.route("POST", "/api/tasks/task-1/request-revision", 200, "{}")
        api.route("POST", "/api/tasks/task-1/fail", 200, "{}")
        let model = await irohAPIModel(api)
        try await model.requestRevision(taskId: "task-1", feedback: "Tighten it")
        try await model.failTask(taskId: "task-1", reason: "Wrong approach")
        XCTAssertTrue(api.calls.contains { $0.method == "POST" && $0.path == "/api/tasks/task-1/request-revision" })
        XCTAssertTrue(api.calls.contains { $0.method == "POST" && $0.path == "/api/tasks/task-1/fail" })
        do {
            try await model.deletePipeline(id: "job-1")
            XCTFail("delete is not on the iroh allowlist")
        } catch {
            XCTAssertEqual(error as? HubError, .transport(.notSupported))
        }
        XCTAssertFalse(api.calls.contains { $0.method == "DELETE" })
    }

    func testUsageRefreshAsksTheHubToReadAgainOverLAN() async {
        stub { request in
            request.url.path == "/api/usage/refresh-all" && request.method == "POST"
                ? .response(200, Data(#"[{"id":"acc-9","name":"Example","provider":"claude"}]"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await waitUntil("usage") { model.usageSnapshot != nil }
        XCTAssertEqual(model.usage.count, 2)
        await model.refreshUsageFromHub()
        XCTAssertEqual(model.usage.map { $0.id }, ["acc-9"])
        XCTAssertFalse(model.usageRefreshing)
    }

    func testUsageRefreshFallsBackToReadingAccountsWhenTheHubRefreshFails() async {
        stub { request in
            request.url.path == "/api/usage/refresh-all" ? .response(500, Data("boom".utf8)) : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await model.refreshUsageFromHub()
        XCTAssertEqual(model.usage.count, 2)
        XCTAssertNil(model.usageState.failureMessage)
    }

    func testUsageRefreshOverIrohOnlyReadsTheAccounts() async {
        let api = FakeAPITransport()
        let model = await irohAPIModel(api)
        await waitUntil("usage over iroh") { model.usageSnapshot != nil }
        await model.refreshUsageFromHub()
        XCTAssertFalse(api.calls.contains { $0.path == "/api/usage/refresh-all" })
        XCTAssertGreaterThanOrEqual(api.calls.filter { $0.path == "/api/usage/accounts" }.count, 2)
    }

    func testSessionsRefreshReadsLogsThenLiveSessionsAndStampsTheTime() async throws {
        stub { request in
            request.url.path == "/api/console/logs"
                ? .response(200, Data(#"[{"id":41,"agent":"codex","source":"stdout","content":"from the backfill","timestamp":"2026-01-01T00:00:00Z","session_id":"sess-41"}]"#.utf8))
                : nil
        }
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await waitUntil("first read") { model.sessionsUpdatedAt != nil }
        nowBox.date = nowBox.date.addingTimeInterval(90)
        await model.refreshSessionsNow()
        XCTAssertEqual(model.sessionsUpdatedAt, nowBox.date)
        XCTAssertTrue(model.consoleLines.contains { $0.content == "from the backfill" })
        let logs = try XCTUnwrap(StubURLProtocol.requests.last { $0.url.path == "/api/console/logs" })
        XCTAssertEqual(logs.url.query?.hasPrefix("agent=all&limit=250"), true)
        XCTAssertEqual(model.sessions.first?.id, "session-1")
    }

    func testSendCarriesModelEffortAndFiles() async throws {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        let sent = await model.send(agent: "codex", prompt: "Do it", model: "example-codex", effort: "low",
                                    files: ["a.txt"])
        XCTAssertTrue(sent)
        let post = try XCTUnwrap(StubURLProtocol.requests.last { $0.url.path == "/api/console/dispatch" })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "example-codex")
        XCTAssertEqual(object["effort"] as? String, "low")
        XCTAssertEqual(object["files"] as? [String], ["a.txt"])
    }

    func testStatusLineNamesTheHubOnceItAnswers() async {
        let session = ScriptedSession(route: .lan)
        let model = makeModel(lan: TransportScript([TransportScript.session(session)]))
        await pairAndConnect(model, lanSession: session)
        await waitUntil("status line") { model.statusLine == "Test Hub is healthy" }
        XCTAssertFalse(model.statusLine.contains("Loopback"))
    }
}

private let phaseACreatedJob = #"{"id":"job-new","title":"Example pipeline","description":"","status":"pending","tasks":{"task-a":{"id":"task-a","job_id":"job-new","title":"Build","assigned_agent":"codex","status":"ready","dependencies":[]}}}"#
