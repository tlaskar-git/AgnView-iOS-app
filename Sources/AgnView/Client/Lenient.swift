import Foundation

/// Lenient reads for hub JSON. The real hub sends null where a value is
/// missing, numbers where the API document said strings and the reverse, and
/// one odd element must never fail a whole list.
extension KeyedDecodingContainer {
    /// A string, or a number or boolean rendered as a string. Nil for null,
    /// a missing key or any other shape.
    func lenientString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? "true" : "false" }
        return nil
    }

    /// A number, or a numeric string. Nil for null, a missing key or junk.
    func lenientDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// A whole number, or a numeric string. Nil for null, a missing key or junk.
    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           abs(value) < 9e15 {
            return Int(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text) ?? Double(text).flatMap { $0.isFinite && abs($0) < 9e15 ? Int($0) : nil }
        }
        return nil
    }

    /// A boolean, or 0/1, or "true"/"false". Nil for null, a missing key or junk.
    func lenientBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// Strings from an array, dropping anything that is not a string.
    func lenientStrings(forKey key: Key) -> [String] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [String] = []
        while !list.isAtEnd {
            if let text = try? list.decode(String.self) {
                out.append(text)
            } else {
                _ = try? list.decode(SkipValue.self)
            }
        }
        return out
    }
}

/// Consumes one JSON value of any shape.
struct SkipValue: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Decodes one element or nothing, so a bad element leaves the list intact.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A list where every element decodes on its own. Elements that fail are
/// dropped and counted.
struct LenientList<T: Decodable>: Decodable {
    let items: [T]
    let dropped: Int

    init(items: [T], dropped: Int) {
        self.items = items
        self.dropped = dropped
    }

    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var good: [T] = []
        var bad = 0
        while !list.isAtEnd {
            // Failable never throws, so the cursor always moves on.
            if let value = try list.decode(Failable<T>.self).value {
                good.append(value)
            } else {
                bad += 1
            }
        }
        items = good
        dropped = bad
    }
}

/// Reads the list out of a hub answer that is a bare array or an object that
/// wraps the array under a known key.
enum HubList {
    static let envelopeKeys = ["items", "data", "results", "jobs", "accounts", "sessions", "logs", "rows"]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let list: LenientList<T>?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var found: LenientList<T>?
            for name in HubList.envelopeKeys {
                guard let key = AnyKey(stringValue: name), c.contains(key) else { continue }
                if let list = try? c.decode(LenientList<T>.self, forKey: key) {
                    found = list
                    break
                }
            }
            list = found
        }
    }

    /// Decodes a list. Throws protocolViolation only when the body is neither
    /// a list nor an object with a list in it.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                     decoder: JSONDecoder = HubJSON.decoder()) throws -> LenientList<T> {
        if let list = try? decoder.decode(LenientList<T>.self, from: data) { return list }
        if let envelope = try? decoder.decode(Envelope<T>.self, from: data), let list = envelope.list {
            return list
        }
        throw TransportError.protocolViolation
    }
}

/// Reads the timestamps the hub sends. It writes ISO 8601 with six fraction
/// digits and a +00:00 offset, and a comment line with a space in place of
/// the T. Foundation reads three fraction digits at most, so the fraction is
/// cut to three. A missing offset means UTC. Nil for anything unreadable.
enum HubDate {
    static func parse(_ raw: String?) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        if text.count > 10 {
            let index = text.index(text.startIndex, offsetBy: 10)
            if text[index] == " " { text.replaceSubrange(index...index, with: "T") }
        }
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = String(text[range].dropFirst().prefix(3))
            text.replaceSubrange(range, with: "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        if let range = text.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            let offset = String(text[range])
            text.replaceSubrange(range, with: String(offset.prefix(3)) + ":" + String(offset.suffix(2)))
        } else if text.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil {
            text += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
