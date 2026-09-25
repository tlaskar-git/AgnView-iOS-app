import Foundation

/// One frame of the console stream. Over iroh the hub writes these as NDJSON.
/// Over LAN the session builds the same frames from HTTP responses.
enum ConsoleFrame: Equatable, Codable {
    case hello(Hello)
    case log(LogEntry)
    case ping(transport: String?)
    case error(detail: String)

    /// The detail string the hub sends when the token does not match.
    static let unauthorisedDetail = "unauthorised"

    struct Hello: Codable, Equatable {
        var app: String?
        var protocolVersion: Int?
        var hostname: String?
        var transport: String?

        enum CodingKeys: String, CodingKey {
            case app
            case protocolVersion = "protocol"
            case hostname
            case transport
        }
    }

    struct LogEntry: Codable, Equatable {
        var id: Int?
        var agent: String?
        var source: String?
        var content: String?
        var timestamp: String?
        var sessionId: String?

        enum CodingKeys: String, CodingKey {
            case id, agent, source, content, timestamp
            case sessionId = "session_id"
        }

        init(id: Int?, agent: String?, source: String?, content: String?,
             timestamp: String?, sessionId: String?) {
            self.id = id
            self.agent = agent
            self.source = source
            self.content = content
            self.timestamp = timestamp
            self.sessionId = sessionId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The hub row id is an integer. Accept a numeric string as well.
            if let number = try? c.decodeIfPresent(Int.self, forKey: .id) {
                id = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .id) {
                id = Int(text)
            } else {
                id = nil
            }
            agent = c.lenientString(forKey: .agent)
            source = c.lenientString(forKey: .source)
            content = c.lenientString(forKey: .content)
            timestamp = c.lenientString(forKey: .timestamp)
            sessionId = c.lenientString(forKey: .sessionId)
        }
    }

    enum FrameType: String, Codable {
        case hello, log, ping, error
    }

    private enum TypeKey: String, CodingKey {
        case type, transport, detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(FrameType.self, forKey: .type)
        switch type {
        case .hello:
            self = .hello(try Hello(from: decoder))
        case .log:
            self = .log(try LogEntry(from: decoder))
        case .ping:
            self = .ping(transport: try c.decodeIfPresent(String.self, forKey: .transport))
        case .error:
            self = .error(detail: try c.decodeIfPresent(String.self, forKey: .detail) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .hello(let hello):
            try c.encode(FrameType.hello, forKey: .type)
            try hello.encode(to: encoder)
        case .log(let entry):
            try c.encode(FrameType.log, forKey: .type)
            try entry.encode(to: encoder)
        case .ping(let transport):
            try c.encode(FrameType.ping, forKey: .type)
            try c.encodeIfPresent(transport, forKey: .transport)
        case .error(let detail):
            try c.encode(FrameType.error, forKey: .type)
            try c.encode(detail, forKey: .detail)
        }
    }

    /// Decodes one NDJSON line. Returns nil for an unknown frame type or an
    /// unreadable line, so a newer hub never breaks an older app.
    static func decode(line: Data) -> ConsoleFrame? {
        try? JSONDecoder().decode(ConsoleFrame.self, from: line)
    }

    /// The route this frame reports, when it reports one.
    var reportedRoute: TransportRoute? {
        switch self {
        case .hello(let hello): return TransportRoute(hubValue: hello.transport)
        case .ping(let transport): return TransportRoute(hubValue: transport)
        default: return nil
        }
    }

    /// Maps an error frame to a transport error.
    static func mapError(detail: String) -> TransportError {
        detail == unauthorisedDetail ? .unauthorised : .protocolViolation
    }
}
