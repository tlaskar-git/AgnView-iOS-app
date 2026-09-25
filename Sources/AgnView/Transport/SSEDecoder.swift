import Foundation

struct SSEEvent: Equatable {
    var type: String
    var data: String
    var id: String?
}

/// Decodes a text/event-stream body into events.
///
/// Feed raw chunks with `feed(_:)` or single lines with `feed(line:)`.
/// A blank line ends an event. Lines that start with a colon are comments.
/// An event with no `event:` field has the type "message".
struct SSEDecoder {
    let maxLineLength: Int
    private var lineBuffer = Data()
    private var eventType: String?
    private var dataLines: [String] = []
    private var lastId: String?

    init(maxLineLength: Int = NDJSONFramer.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if byte == 0x0A {
                var line = lineBuffer
                lineBuffer = Data()
                if line.last == 0x0D { line.removeLast() }
                if let event = feed(line: String(decoding: line, as: UTF8.self)) {
                    events.append(event)
                }
                continue
            }
            lineBuffer.append(byte)
            if lineBuffer.count > maxLineLength {
                lineBuffer.removeAll(keepingCapacity: false)
                throw TransportError.protocolViolation
            }
        }
        return events
    }

    /// Processes one line without its line ending. Returns an event when the
    /// line is blank and an event is pending.
    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastId = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            dataLines = []
        }
        if dataLines.isEmpty && eventType == nil {
            return nil
        }
        return SSEEvent(type: eventType ?? "message",
                        data: dataLines.joined(separator: "\n"),
                        id: lastId)
    }
}
