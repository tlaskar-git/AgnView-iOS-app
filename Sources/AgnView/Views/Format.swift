import Foundation

/// Plain formatters for the screens. No locale surprises: the output is stable.
enum Format {
    /// 999 -> "999", 1500 -> "1.5K", 120000 -> "120K", 1200000 -> "1.2M".
    static func tokens(_ count: Int) -> String {
        let sign = count < 0 ? "-" : ""
        let value = Double(abs(count))
        if value < 1000 { return sign + String(abs(count)) }
        let thousands = (value / 100).rounded() / 10
        if thousands < 1000 { return sign + trim(thousands) + "K" }
        return sign + trim((value / 100_000).rounded() / 10) + "M"
    }

    /// 12.5 -> "$12.50".
    static func cost(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    /// Seconds since a reading -> "just now", "5 min ago", "2 h ago", "3 d ago".
    static func age(seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    static func age(from date: Date, to now: Date) -> String {
        age(seconds: now.timeIntervalSince(date))
    }

    /// 96 -> "96%", 8.5 -> "8.5%".
    static func percent(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
    }

    /// "Updated just now", "Updated 5 min ago" or "Not updated yet".
    static func updated(from date: Date?, to now: Date) -> String {
        guard let date else { return "Not updated yet" }
        return "Updated " + age(from: date, to: now)
    }

    /// "Last reading 5 min ago", from an age in seconds.
    static func lastReading(seconds: TimeInterval) -> String {
        "Last reading " + age(seconds: seconds)
    }

    /// The age of a usage reading now: the age the hub reported when it
    /// answered, plus the time since the app took the answer. Without a hub
    /// age, only the time since the app took it.
    static func readingAge(hubAgeSeconds: Double?, takenAt: Date, now: Date) -> TimeInterval {
        max(0, hubAgeSeconds ?? 0) + max(0, now.timeIntervalSince(takenAt))
    }

    /// "Last reading 5 min ago".
    static func lastReading(from date: Date, to now: Date) -> String {
        "Last reading " + age(from: date, to: now)
    }

    /// Share of a limit that is used, from 0 to 1. Nil when there is no usable limit.
    static func fraction(used: Double, limit: Double?) -> Double? {
        guard let limit, limit > 0 else { return nil }
        return min(1, max(0, used / limit))
    }

    static func agentName(_ raw: String) -> String {
        switch raw {
        case "claude_code": return "Claude Code"
        case "codex": return "Codex"
        case "antigravity": return "AntiGravity"
        case "deepseek": return "DeepSeek"
        case "custom": return "Custom"
        case "system": return "System"
        case "user": return "You"
        default: return raw.isEmpty ? "Agent" : raw
        }
    }

    static func providerName(_ raw: String) -> String {
        switch raw {
        case "claude": return "Claude"
        case "chatgpt": return "ChatGPT"
        case "gemini": return "Gemini"
        case "antigravity": return "AntiGravity"
        default: return raw.capitalized
        }
    }

    /// First eight characters of a session id, for display.
    static func shortId(_ id: String) -> String {
        String(id.prefix(8))
    }

    private static func trim(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
