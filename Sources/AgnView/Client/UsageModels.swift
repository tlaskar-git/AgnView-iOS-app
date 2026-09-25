import Foundation

/// One limit window on a usage card, as the hub renders it (`usage.windows[]`
/// of GET /api/usage/accounts). Every figure and every text here comes from
/// the hub. `amountText` is nil when the hub measured nothing for the window.
struct UsageWindowRow: Codable, Equatable, Identifiable {
    let key: String
    let label: String
    let subLabel: String?
    let unit: String?
    let amountText: String?
    let percentUsed: Double?
    let hasBar: Bool
    let severity: String?
    let isActive: Bool
    let countdownText: String?
    let breakdown: [UsageWindowRow]

    var id: String { key + "|" + label }

    /// True when the hub returned no figure, so the card says "Not measured yet".
    var isMeasured: Bool { amountText != nil }

    /// A bar is drawn only when the hub gave a share to draw.
    var barFraction: Double? {
        guard hasBar, let percentUsed else { return nil }
        return min(1, max(0, percentUsed / 100))
    }

    /// The share left, for the "N% left" text. Nil without a share.
    var percentLeft: Double? {
        guard hasBar, let percentUsed else { return nil }
        return max(0, (100 - percentUsed) * 10).rounded() / 10
    }

    init(key: String, label: String, subLabel: String? = nil, unit: String? = nil,
         amountText: String? = nil, percentUsed: Double? = nil, hasBar: Bool? = nil,
         severity: String? = nil, isActive: Bool = false, countdownText: String? = nil,
         breakdown: [UsageWindowRow] = []) {
        self.key = key
        self.label = label
        self.subLabel = subLabel
        self.unit = unit
        self.amountText = amountText
        self.percentUsed = percentUsed
        self.hasBar = hasBar ?? (percentUsed != nil)
        self.severity = severity
        self.isActive = isActive
        self.countdownText = countdownText
        self.breakdown = breakdown
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, subLabel, unit, amountText, percentUsed, hasBar
        case severity, isActive, countdownText, breakdown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let label = c.lenientString(forKey: .label)
        let key = c.lenientString(forKey: .key)
        guard label != nil || key != nil else {
            throw DecodingError.keyNotFound(CodingKeys.label, .init(codingPath: c.codingPath,
                                                                    debugDescription: "window label"))
        }
        self.key = key ?? label ?? ""
        self.label = label ?? key ?? ""
        subLabel = c.lenientString(forKey: .subLabel)
        unit = c.lenientString(forKey: .unit)
        amountText = c.lenientString(forKey: .amountText)
        let percent = c.lenientDouble(forKey: .percentUsed)
        percentUsed = percent
        hasBar = c.lenientBool(forKey: .hasBar) ?? (percent != nil)
        severity = c.lenientString(forKey: .severity)
        isActive = c.lenientBool(forKey: .isActive) ?? false
        countdownText = c.lenientString(forKey: .countdownText)
        if let list = try? c.decodeIfPresent(LenientList<UsageWindowRow>.self, forKey: .breakdown) {
            breakdown = list.items
        } else {
            breakdown = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(subLabel, forKey: .subLabel)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encode(amountText, forKey: .amountText)
        try c.encode(percentUsed, forKey: .percentUsed)
        try c.encode(hasBar, forKey: .hasBar)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(countdownText, forKey: .countdownText)
        try c.encode(breakdown, forKey: .breakdown)
    }
}

/// The `usage` block of an account: what the card shows. The raw
/// `observation` block that sits beside it is not read.
struct UsageDetail: Codable, Equatable {
    let sourceLabel: String?
    let ageText: String?
    /// Seconds between the hub's reading and its answer. Nil when the hub never read the account.
    let ageSeconds: Double?
    let isStale: Bool
    let planLabel: String?
    let planName: String?
    let error: String?
    let windows: [UsageWindowRow]

    init(sourceLabel: String? = nil, ageText: String? = nil, ageSeconds: Double? = nil,
         isStale: Bool = false, planLabel: String? = nil, planName: String? = nil,
         error: String? = nil, windows: [UsageWindowRow] = []) {
        self.sourceLabel = sourceLabel
        self.ageText = ageText
        self.ageSeconds = ageSeconds
        self.isStale = isStale
        self.planLabel = planLabel
        self.planName = planName
        self.error = error
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case sourceLabel, ageText, ageSeconds, isStale, planLabel, planName, error, windows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLabel = c.lenientString(forKey: .sourceLabel)
        ageText = c.lenientString(forKey: .ageText)
        ageSeconds = c.lenientDouble(forKey: .ageSeconds)
        isStale = c.lenientBool(forKey: .isStale) ?? false
        planLabel = c.lenientString(forKey: .planLabel)
        planName = c.lenientString(forKey: .planName)
        error = c.lenientString(forKey: .error)
        if let list = try? c.decodeIfPresent(LenientList<UsageWindowRow>.self, forKey: .windows) {
            windows = list.items
        } else {
            windows = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceLabel, forKey: .sourceLabel)
        try c.encodeIfPresent(ageText, forKey: .ageText)
        try c.encodeIfPresent(ageSeconds, forKey: .ageSeconds)
        try c.encode(isStale, forKey: .isStale)
        try c.encodeIfPresent(planLabel, forKey: .planLabel)
        try c.encodeIfPresent(planName, forKey: .planName)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(windows, forKey: .windows)
    }
}

extension UsageAccount {
    /// The plan text for the card: the hub's plan label, then its plan name.
    var displayPlan: String? {
        for candidate in [usage?.planLabel, planLabel, usage?.planName, planName] {
            if let text = candidate, !text.isEmpty { return text }
        }
        return nil
    }

    /// The error the card shows: the hub's own reason for an unread account.
    var displayError: String? {
        for candidate in [errorMessage, usage?.error] {
            if let text = candidate, !text.isEmpty { return text }
        }
        return nil
    }

    /// True when the hub sent windows to draw.
    var hasWindows: Bool { !(usage?.windows.isEmpty ?? true) }
}
