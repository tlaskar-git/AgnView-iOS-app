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
            XCTAssertEqual(error.message, "Sending prompts needs the same Wi-Fi as your computer.")
            XCTAssertEqual(error.localizedDescription, error.message)
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url.path == "/api/console/dispatch" })
        XCTAssertEqual(model.usageNotice, "Usage needs the same Wi-Fi as your computer.")
        XCTAssertEqual(model.jobsNotice, "Pipelines need the same Wi-Fi as your computer.")
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
        XCTAssertEqual(model.dispatchNotice, UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(model.usageNotice, UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(model.jobsNotice, UserMessages.pairedWithoutLANBanner)
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
        XCTAssertEqual(model.dispatchNotice, "Sending prompts needs the same Wi-Fi as your computer.")
        XCTAssertEqual(model.usageNotice, "Usage needs the same Wi-Fi as your computer.")
        XCTAssertEqual(model.jobsNotice, "Pipelines need the same Wi-Fi as your computer.")
    }

    func testMessageSelectionByReason() {
        XCTAssertEqual(UserMessages.lanBanner(.pairedWithoutLAN), UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(UserMessages.lanBanner(.notOnSameNetwork), UserMessages.notOnSameNetworkBanner)
        XCTAssertEqual(UserMessages.dispatchNeedsLAN(.pairedWithoutLAN), UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(UserMessages.usageNeedsLAN(.pairedWithoutLAN), UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(UserMessages.jobsNeedsLAN(.pairedWithoutLAN), UserMessages.pairedWithoutLANBanner)
        XCTAssertEqual(UserMessages.dispatchNeedsLAN(.notOnSameNetwork),
                       "Sending prompts needs the same Wi-Fi as your computer.")
        XCTAssertEqual(UserMessages.usageNeedsLAN(.notOnSameNetwork),
                       "Usage needs the same Wi-Fi as your computer.")
        XCTAssertEqual(UserMessages.jobsNeedsLAN(.notOnSameNetwork),
                       "Pipelines need the same Wi-Fi as your computer.")
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
        XCTAssertEqual(model.usageNotice, UserMessages.usageNeedsLAN(.notOnSameNetwork))
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
        XCTAssertEqual(model.usageNotice, UserMessages.usageNeedsLAN(.notOnSameNetwork))
        XCTAssertEqual(model.usageSnapshot?.takenAt, nowBox.date.addingTimeInterval(-300))
    }

    func testUnknownForcedStateRunsNormally() async {
        let model = forced("not-a-state")
        XCTAssertEqual(model.connection, .offline(retryIn: nil))
        XCTAssertTrue(model.hubs.isEmpty)
    }
    #endif
}
