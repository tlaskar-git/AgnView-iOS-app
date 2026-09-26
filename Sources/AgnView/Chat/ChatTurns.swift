import Foundation

/// A piece of an agent reply: plain text or a fenced code block.
enum ChatBlock: Equatable {
    case text(String)
    case code(language: String, source: String)
}

/// One agent reply. Consecutive console lines of one agent in one session are
/// one reply, joined with newlines.
struct ChatReply: Equatable, Identifiable {
    let id: String
    let agent: String
    let sessionId: String?
    /// The joined lines.
    var text: String
    var blocks: [ChatBlock]
    /// When the newest line of this reply arrived, if the hub said.
    var lastLineTime: Date?

    var agentName: String { Format.agentName(agent) }
}

/// One thing in the conversation.
enum ChatItem: Equatable, Identifiable {
    /// A light time label between groups, such as "Today, 09:41" or "09:52".
    case separator(id: String, text: String)
    /// A hub or app notice, centred.
    case system(id: String, text: String)
    /// What the user sent: a right aligned bubble.
    case user(id: String, text: String)
    /// What an agent answered: plain text under an agent label.
    case agent(ChatReply)

    var id: String {
        switch self {
        case .separator(let id, _), .system(let id, _), .user(let id, _): return id
        case .agent(let reply): return reply.id
        }
    }
}

/// Splits reply text into text and fenced code blocks.
enum ChatCode {
    /// A line that starts with three backticks opens or closes a fence. The
    /// words after the opening backticks are the language. A fence that is
    /// still open at the end, as while an agent is answering, is a code block
    /// with what has arrived so far.
    static func parse(_ text: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var proseLines: [Substring] = []
        var codeLines: [Substring] = []
        var language = ""
        var inCode = false

        func flushProse() {
            let joined = proseLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            proseLines.removeAll()
            if !joined.isEmpty { blocks.append(.text(joined)) }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, source: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushProse()
                    language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        if inCode {
            blocks.append(.code(language: language, source: codeLines.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return blocks
    }

    /// The label on a code block: the language with a capital, or "Code".
    static func displayName(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "Code" }
        return first.uppercased() + trimmed.dropFirst()
    }
}

/// Reads the timestamps of console lines.
enum ChatTime {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// A hub time without a zone, such as 2026-01-01T09:41:00.123456, is read as UTC.
    private static let naive: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = $0
        return formatter
    }

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = fractional.date(from: text) { return date }
        if let date = plain.date(from: text) { return date }
        for formatter in naive {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Builds the conversation from the console lines. It keeps what it built, so
/// a new line costs one step and nothing is parsed twice. When the lines are
/// not the old ones plus new ones (the ring buffer dropped the oldest, or the
/// hub changed), it builds again from the start.
struct ChatBuilder {
    /// Two lines further apart than this start a new group with a time label.
    static let groupGap: TimeInterval = 300

    private(set) var items: [ChatItem] = []

    private var calendar: Calendar
    private var processed = 0
    private var firstId: Int?
    private var lastId: Int?
    private var lastTurnTime: Date?
    private var lastSeparatorDay: Date?
    /// The index in `items` of the reply that can still grow.
    private var openReply: Int?
    private var now = Date()
    private let clockFormatter: DateFormatter
    private let dateFormatter: DateFormatter

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_GB")
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        clockFormatter = clock
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_GB")
        date.timeZone = calendar.timeZone
        date.dateFormat = "d MMM"
        dateFormatter = date
    }

    /// Brings the conversation up to date. Returns true when it changed.
    @discardableResult
    mutating func sync(_ lines: [ConsoleLine], now: Date = Date()) -> Bool {
        self.now = now
        if lines.isEmpty {
            guard processed > 0 || !items.isEmpty else { return false }
            reset()
            return true
        }
        let extendsOld = processed > 0
            && processed <= lines.count
            && lines.first?.id == firstId
            && lines[processed - 1].id == lastId
        if !extendsOld { reset() }
        let start = extendsOld ? processed : 0
        guard start < lines.count else { return false }
        for index in start..<lines.count { append(lines[index]) }
        processed = lines.count
        firstId = lines.first?.id
        lastId = lines.last?.id
        return true
    }

    private mutating func reset() {
        items = []
        processed = 0
        firstId = nil
        lastId = nil
        lastTurnTime = nil
        lastSeparatorDay = nil
        openReply = nil
    }

    private enum Kind { case system, user, agent }

    private func kind(of line: ConsoleLine) -> Kind {
        switch line.agent {
        case "", "system": return .system
        case "user": return .user
        default: return .agent
        }
    }

    private mutating func append(_ line: ConsoleLine) {
        let time = ChatTime.parse(line.timestamp)
        switch kind(of: line) {
        case .system:
            openReply = nil
            items.append(.system(id: "s\(line.id)", text: line.content))
        case .user:
            openReply = nil
            addSeparatorIfNeeded(before: "u\(line.id)", time: time)
            items.append(.user(id: "u\(line.id)", text: line.content))
        case .agent:
            if let index = openReply, case .agent(var reply) = items[index],
               reply.agent == line.agent, reply.sessionId == line.sessionId,
               withinGap(reply.lastLineTime, time) {
                reply.text += "\n" + line.content
                reply.blocks = ChatCode.parse(reply.text)
                reply.lastLineTime = time ?? reply.lastLineTime
                items[index] = .agent(reply)
                if let time { lastTurnTime = time }
            } else {
                addSeparatorIfNeeded(before: "r\(line.id)", time: time)
                let reply = ChatReply(id: "r\(line.id)", agent: line.agent, sessionId: line.sessionId,
                                      text: line.content, blocks: ChatCode.parse(line.content),
                                      lastLineTime: time)
                items.append(.agent(reply))
                openReply = items.count - 1
            }
        }
    }

    private func withinGap(_ previous: Date?, _ current: Date?) -> Bool {
        guard let previous, let current else { return true }
        return abs(current.timeIntervalSince(previous)) < Self.groupGap
    }

    private mutating func addSeparatorIfNeeded(before id: String, time: Date?) {
        guard let time else { return }
        defer { lastTurnTime = time }
        if let last = lastTurnTime,
           time.timeIntervalSince(last) < Self.groupGap,
           calendar.isDate(time, inSameDayAs: last) {
            return
        }
        items.append(.separator(id: "t" + id, text: separatorText(for: time)))
    }

    /// The first label of a day names the day, the next ones show the time.
    private mutating func separatorText(for time: Date) -> String {
        let clock = clockFormatter.string(from: time)
        let day = calendar.startOfDay(for: time)
        defer { lastSeparatorDay = day }
        if lastSeparatorDay == day { return clock }
        if calendar.isDate(time, inSameDayAs: now) { return "Today, " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(time, inSameDayAs: yesterday) {
            return "Yesterday, " + clock
        }
        return dateFormatter.string(from: time) + ", " + clock
    }
}

/// When the pulsing dot shows at the end of the last agent reply.
enum ChatStreaming {
    /// A reply counts as still being written when its newest line is younger.
    static let window: TimeInterval = 8

    /// True when this is the last item, its newest line is under eight seconds
    /// old and its session is live. A session from the live list counts when
    /// it is busy. A session the app only knows from log lines counts as live
    /// while lines keep coming, and so does a session the list does not name.
    static func isStreaming(lastLineTime: Date?, now: Date, isLastItem: Bool, session: SessionInfo?) -> Bool {
        guard isLastItem, let lastLineTime else { return false }
        let age = now.timeIntervalSince(lastLineTime)
        guard age < window else { return false }
        guard let session else { return true }
        return session.fromLog || session.busy
    }
}
