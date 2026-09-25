import XCTest
@testable import AgnView

final class LadderTests: XCTestCase {
    private func ladder(_ endpoint: FakeEndpoint = FakeEndpoint(), clock: FakeClock,
                        lan: FakeTransport, iroh: Transport) -> ConnectionLadder {
        ConnectionLadder(endpoint: endpoint, clock: clock,
                         makeLAN: { _ in lan },
                         makeIroh: { _, _ in iroh })
    }

    func testLANWinsInsideBudget() async {
        let clock = FakeClock()
        let lan = FakeTransport.session(.lan)
        let iroh = FakeTransport.session(.direct)
        let result = await ladder(clock: clock, lan: lan, iroh: iroh).resolve()
        XCTAssertEqual(result.session?.route, .lan)
        XCTAssertEqual(result.session?.capabilities, Set<Capability>.lan)
        XCTAssertFalse(result.relayOnly)
        XCTAssertEqual(lan.connectCount, 1)
        XCTAssertEqual(iroh.connectCount, 0)
    }

    func testExpiryAt800msFallsToIroh() async {
        let clock = FakeClock()
        let lan = FakeTransport.hanging()
        let iroh = FakeTransport.session(.direct)
        let task = Task { await self.ladder(clock: clock, lan: lan, iroh: iroh).resolve() }

        let waiting = await clock.waitForSleepers(1)
        XCTAssertTrue(waiting)
        clock.advance(by: .milliseconds(799))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(iroh.connectCount, 0, "iroh must wait for the full 800 ms")

        clock.advance(by: .milliseconds(1))
        let result = await task.value
        XCTAssertEqual(result.session?.route, .direct)
        XCTAssertEqual(result.session?.capabilities, [.consoleStream])
        XCTAssertFalse(result.relayOnly)
        XCTAssertEqual(iroh.connectCount, 1)
    }

    func testFastLANFailureFallsToIroh() async {
        let clock = FakeClock()
        let lan = FakeTransport.failing(.unreachable)
        let iroh = FakeTransport.session(.relay)
        let result = await ladder(clock: clock, lan: lan, iroh: iroh).resolve()
        XCTAssertEqual(result.session?.route, .relay)
        XCTAssertFalse(result.relayOnly)
    }

    func testLoopbackSkipsLANAndSetsRelayOnly() async {
        let clock = FakeClock()
        let lan = FakeTransport.session(.lan)
        let iroh = FakeTransport.session(.relay)
        var endpoint = FakeEndpoint()
        endpoint.lanHost = "127.0.0.1"
        endpoint.isLoopbackLAN = true
        let result = await ladder(endpoint, clock: clock, lan: lan, iroh: iroh).resolve()
        XCTAssertEqual(lan.connectCount, 0)
        XCTAssertEqual(result.session?.route, .relay)
        XCTAssertTrue(result.relayOnly)
    }

    func testIrohDirectFromHello() async {
        let hello = #"{"type":"hello","app":"AgnView","protocol":1,"hostname":"example-host","transport":"iroh-direct"}"# + "\n"
        var endpoint = FakeEndpoint()
        endpoint.isLoopbackLAN = true
        let result = await ladder(endpoint, clock: FakeClock(), lan: .session(.lan),
                                  iroh: ScriptedStreamTransport([hello])).resolve()
        XCTAssertEqual(result.session?.route, .direct)
        XCTAssertTrue(result.relayOnly)
    }

    func testIrohRelayFromHello() async {
        let hello = #"{"type":"hello","app":"AgnView","protocol":1,"hostname":"example-host","transport":"iroh-relay"}"# + "\n"
        let result = await ladder(clock: FakeClock(), lan: .failing(.unreachable),
                                  iroh: ScriptedStreamTransport([hello])).resolve()
        XCTAssertEqual(result.session?.route, .relay)
    }

    func testUnauthorisedStopsImmediately() async {
        let clock = FakeClock()
        let lan = FakeTransport.failing(.unauthorised)
        let iroh = FakeTransport.session(.direct)
        let result = await ladder(clock: clock, lan: lan, iroh: iroh).resolve()
        XCTAssertEqual(result.error, .unauthorised)
        XCTAssertEqual(iroh.connectCount, 0)
    }

    func testRateLimitStops() async {
        let clock = FakeClock()
        let lan = FakeTransport.failing(.rateLimited)
        let iroh = FakeTransport.session(.direct)
        let result = await ladder(clock: clock, lan: lan, iroh: iroh).resolve()
        XCTAssertEqual(result.error, .rateLimited)
        XCTAssertEqual(iroh.connectCount, 0)
    }

    func testIrohUnauthorised() async {
        let error = #"{"type":"error","detail":"unauthorised"}"# + "\n"
        let result = await ladder(clock: FakeClock(), lan: .failing(.unreachable),
                                  iroh: ScriptedStreamTransport([error])).resolve()
        XCTAssertEqual(result.error, .unauthorised)
    }

    func testNoTicketGivesUnreachable() async {
        var endpoint = FakeEndpoint()
        endpoint.irohTicket = nil
        let iroh = FakeTransport.session(.direct)
        let result = await ladder(endpoint, clock: FakeClock(), lan: .failing(.unreachable), iroh: iroh).resolve()
        XCTAssertEqual(result.error, .unreachable)
        XCTAssertEqual(iroh.connectCount, 0)
    }

    func testLoopbackWithoutTicketGivesUnreachable() async {
        var endpoint = FakeEndpoint()
        endpoint.isLoopbackLAN = true
        endpoint.irohTicket = nil
        let result = await ladder(endpoint, clock: FakeClock(), lan: .session(.lan),
                                  iroh: FakeTransport.session(.relay)).resolve()
        XCTAssertEqual(result.error, .unreachable)
        XCTAssertFalse(result.relayOnly)
    }

    func testIrohUnavailableIsReported() async {
        let result = await ladder(clock: FakeClock(), lan: .failing(.unreachable),
                                  iroh: FakeTransport.failing(.unavailable)).resolve()
        XCTAssertEqual(result.error, .unavailable)
    }

    // MARK: Watchdog and backoff

    func testPingWatchdogFiresAt45Seconds() async {
        let clock = FakeClock()
        let fired = expectation(description: "watchdog fired")
        let watchdog = PingWatchdog(clock: clock) { fired.fulfill() }
        watchdog.start()
        let waiting = await clock.waitForSleepers(1)
        XCTAssertTrue(waiting)
        clock.advance(by: .seconds(44))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(watchdog.hasFired)
        clock.advance(by: .seconds(1))
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertTrue(watchdog.hasFired)
    }

    func testPingWatchdogKickResets() async {
        let clock = FakeClock()
        let watchdog = PingWatchdog(clock: clock) {}
        watchdog.start()
        _ = await clock.waitForSleepers(1)
        clock.advance(by: .seconds(30))
        watchdog.kick()
        _ = await clock.waitForSleepers(1)
        clock.advance(by: .seconds(30))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(watchdog.hasFired, "a kick at 30 s moves the deadline to 75 s")
        clock.advance(by: .seconds(15))
        let deadline = Date().addingTimeInterval(2)
        while !watchdog.hasFired && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(watchdog.hasFired)
        watchdog.stop()
    }

    func testBackoffSequence() {
        var backoff = Backoff()
        let delays = (0..<7).map { _ in backoff.next() }
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                                .seconds(15), .seconds(15), .seconds(15)])
        backoff.reset()
        XCTAssertEqual(backoff.next(), .seconds(1))
    }

    func testFakeClockSleepWakesOnAdvance() async throws {
        let clock = FakeClock()
        let start = clock.now
        let task = Task { try await clock.sleep(for: .seconds(2)) }
        _ = await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        try await task.value
        XCTAssertEqual(start.duration(to: clock.now), .seconds(2))
    }
}
