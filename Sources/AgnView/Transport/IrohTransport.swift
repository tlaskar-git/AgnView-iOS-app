import Foundation

/// The console request the hub reads once over iroh, before finish().
enum IrohConsoleRequest {
    static let alpn = Data("agnview/console/1".utf8)
    static let readChunkLimit: UInt32 = 64 * 1024

    /// `{"token": <key or null>, "agent": <filter or "all">, "backlog": <int>,
    /// "after_id": <int or null>}`
    static func body(token: String?, agent: String = "all", backlog: Int = 200,
                     afterId: Int? = nil) -> Data {
        let object: [String: Any] = [
            "token": token.map { $0 as Any } ?? NSNull(),
            "agent": agent,
            "backlog": backlog,
            "after_id": afterId.map { $0 as Any } ?? NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

#if canImport(IrohLib)
import IrohLib

/// Console stream and mobile API over iroh. The session has the consoleStream
/// capability always. It has the full set, with an API route that opens one
/// stream per call, when the hello frame lists "api" (hub 0.1.12 or later).
final class IrohTransport: Transport {
    let ticket: String
    let token: String?
    let agent: String
    let backlog: Int
    let afterId: Int?

    init(ticket: String, token: String?, agent: String = "all", backlog: Int = 200, afterId: Int? = nil) {
        self.ticket = ticket
        self.token = token
        self.agent = agent
        self.backlog = backlog
        self.afterId = afterId
    }

    convenience init?(endpoint: HubEndpoint) {
        guard let ticket = endpoint.irohTicket, !ticket.isEmpty else { return nil }
        self.init(ticket: ticket, token: endpoint.token)
    }

    func connect() async throws -> HubSession {
        let parsed: EndpointTicket
        do {
            parsed = try EndpointTicket.fromString(str: ticket)
        } catch {
            throw TransportError.protocolViolation
        }

        let endpoint: Endpoint
        do {
            endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetN0()))
        } catch {
            throw TransportError.unavailable
        }

        let recv: RecvStream
        let connection: Connection
        do {
            connection = try await endpoint.connect(addr: parsed.endpointAddr(), alpn: IrohConsoleRequest.alpn)
            let bi = try await connection.openBi()
            let send = bi.send()
            recv = bi.recv()
            let body = IrohConsoleRequest.body(token: token, agent: agent, backlog: backlog, afterId: afterId)
            try await send.writeAll(buf: body)
            try await send.finish()
        } catch {
            try? await endpoint.close()
            throw TransportError.unreachable
        }

        let limit = IrohConsoleRequest.readChunkLimit
        let apiToken = token ?? ""
        return try await ConsoleStreamSession.open(
            capabilities: .iroh,
            fallbackRoute: .relay,
            makeAPI: {
                IrohAPITransport(token: apiToken, openStream: {
                    let bi = try await connection.openBi()
                    let send = bi.send()
                    let recv = bi.recv()
                    return APIStreamIO(
                        write: { try await send.writeAll(buf: $0) },
                        finish: { try await send.finish() },
                        read: { try await recv.read(sizeLimit: limit) },
                        cancel: {
                            Task {
                                try? await send.reset(errorCode: 0)
                                try? await recv.stop(errorCode: 0)
                            }
                        })
                })
            },
            read: { try await recv.read(sizeLimit: limit) },
            onClose: {
                try? connection.close(errorCode: 0, reason: Data("bye".utf8))
                try? await endpoint.close()
            }
        )
    }
}
#else

/// Stub used when the iroh bindings are not linked into this build.
final class IrohTransport: Transport {
    init(ticket: String, token: String?, agent: String = "all", backlog: Int = 200, afterId: Int? = nil) {}

    convenience init?(endpoint: HubEndpoint) {
        guard let ticket = endpoint.irohTicket, !ticket.isEmpty else { return nil }
        self.init(ticket: ticket, token: endpoint.token)
    }

    func connect() async throws -> HubSession {
        throw TransportError.unavailable
    }
}
#endif

enum IrohSupport {
    /// True when this build links the iroh bindings.
    static var isLinked: Bool {
        #if canImport(IrohLib)
        return true
        #else
        return false
        #endif
    }
}
