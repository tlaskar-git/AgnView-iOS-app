import Foundation

enum LadderResult {
    case connected(HubSession, relayOnly: Bool)
    case failed(TransportError)

    /// True when LAN was skipped because the pairing carries a loopback
    /// address and iroh connected.
    var relayOnly: Bool {
        if case .connected(_, let relayOnly) = self { return relayOnly }
        return false
    }

    var session: HubSession? {
        if case .connected(let session, _) = self { return session }
        return nil
    }

    var error: TransportError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// Tries the rungs in the order PAIRING.md sets: LAN inside 800 ms, then iroh
/// (direct or relay, which iroh decides). The route shown to the user comes
/// from the session, which takes it from hello.transport.
struct ConnectionLadder {
    static let lanBudget: Duration = .milliseconds(800)

    typealias MakeLAN = (HubEndpoint) -> Transport
    typealias MakeIroh = (HubEndpoint, String) -> Transport

    let endpoint: HubEndpoint
    let clock: Clock
    let makeLAN: MakeLAN
    let makeIroh: MakeIroh

    init(endpoint: HubEndpoint, clock: Clock,
         makeLAN: @escaping MakeLAN = { LANTransport(endpoint: $0) },
         makeIroh: @escaping MakeIroh = { endpoint, ticket in
             IrohTransport(ticket: ticket, token: endpoint.token)
         }) {
        self.endpoint = endpoint
        self.clock = clock
        self.makeLAN = makeLAN
        self.makeIroh = makeIroh
    }

    private enum Probe {
        case connected(HubSession)
        case failed(TransportError)
        case expired
    }

    func resolve() async -> LadderResult {
        let skippedLAN = endpoint.isLoopbackLAN
        if !skippedLAN {
            switch await probeLAN() {
            case .connected(let session):
                return .connected(session, relayOnly: false)
            case .failed(.unauthorised):
                return .failed(.unauthorised)
            case .failed(.rateLimited):
                return .failed(.rateLimited)
            case .failed, .expired:
                break
            }
        }

        guard let ticket = endpoint.irohTicket, !ticket.isEmpty else {
            return .failed(.unreachable)
        }
        do {
            let session = try await makeIroh(endpoint, ticket).connect()
            return .connected(session, relayOnly: skippedLAN)
        } catch {
            return .failed(TransportError.normalise(error))
        }
    }

    /// Races the LAN connect (GET /api/mobile/status) against the budget.
    private func probeLAN() async -> Probe {
        let lan = makeLAN(endpoint)
        let clock = self.clock
        return await withTaskGroup(of: Probe.self) { group in
            group.addTask {
                do {
                    return .connected(try await lan.connect())
                } catch {
                    return .failed(TransportError.normalise(error))
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(for: ConnectionLadder.lanBudget)
                    return .expired
                } catch {
                    return .expired
                }
            }
            let first = await group.next() ?? .expired
            group.cancelAll()
            // A LAN session that arrives after the budget is closed, not used.
            for await late in group {
                if case .connected(let session) = late {
                    await session.close()
                }
            }
            return first
        }
    }
}
