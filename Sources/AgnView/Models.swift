import Foundation

struct UsageAccount: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let provider: String
    let planName: String?
    let tokensUsed: Int
    let tokensLimit: Int?
    let costUsed: Double
    let costLimit: Double?
    let requestsCount: Int
    let lastProbed: String?
    let isActive: Bool
    /// Hub status string: active, warning, exhausted, unavailable, error, unknown.
    let status: String?
    let planLabel: String?
    let percentUsed: Double?
    let sessionPercentUsed: Double?
    let weeklyPercentUsed: Double?
    /// Why the hub could not measure this account, when it says.
    let errorMessage: String?
    /// False when the hub sent null: the figure is not measured, not zero.
    let hasTokens: Bool
    let hasCost: Bool
    let hasRequests: Bool

    init(id: String, name: String, provider: String, planName: String?, tokensUsed: Int,
         tokensLimit: Int?, costUsed: Double, costLimit: Double?, requestsCount: Int,
         lastProbed: String?, isActive: Bool, status: String? = nil, planLabel: String? = nil,
         percentUsed: Double? = nil, sessionPercentUsed: Double? = nil,
         weeklyPercentUsed: Double? = nil, errorMessage: String? = nil,
         hasTokens: Bool = true, hasCost: Bool = true, hasRequests: Bool = true) {
        self.hasTokens = hasTokens
        self.hasCost = hasCost
        self.hasRequests = hasRequests
        self.id = id
        self.name = name
        self.provider = provider
        self.planName = planName
        self.tokensUsed = tokensUsed
        self.tokensLimit = tokensLimit
        self.costUsed = costUsed
        self.costLimit = costLimit
        self.requestsCount = requestsCount
        self.lastProbed = lastProbed
        self.isActive = isActive
        self.status = status
        self.planLabel = planLabel
        self.percentUsed = percentUsed
        self.sessionPercentUsed = sessionPercentUsed
        self.weeklyPercentUsed = weeklyPercentUsed
        self.errorMessage = errorMessage
    }

    /// The hub names these tokens_used, cost_used_usd, requests_used and
    /// last_checked, and sends null for anything it has not measured. The
    /// older names the API document used are read as well.
    private enum CodingKeys: String, CodingKey {
        case id, name, provider, planName, planLabel, tokensUsed, tokensLimit
        case costUsed, costUsedUsd, costLimit, costLimitUsd
        case requestsCount, requestsUsed, lastProbed, lastChecked, isActive
        case status, percentUsed, sessionPercentUsed, weeklyPercentUsed, errorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "account id"))
        }
        let provider = c.lenientString(forKey: .provider) ?? ""
        let status = c.lenientString(forKey: .status)
        self.id = id
        self.provider = provider
        name = c.lenientString(forKey: .name) ?? provider
        planName = c.lenientString(forKey: .planName)
        planLabel = c.lenientString(forKey: .planLabel)
        let tokens = c.lenientInt(forKey: .tokensUsed)
        let cost = c.lenientDouble(forKey: .costUsedUsd) ?? c.lenientDouble(forKey: .costUsed)
        let requests = c.lenientInt(forKey: .requestsUsed) ?? c.lenientInt(forKey: .requestsCount)
        tokensUsed = tokens ?? 0
        hasTokens = tokens != nil
        tokensLimit = c.lenientInt(forKey: .tokensLimit)
        costUsed = cost ?? 0
        hasCost = cost != nil
        costLimit = c.lenientDouble(forKey: .costLimitUsd) ?? c.lenientDouble(forKey: .costLimit)
        requestsCount = requests ?? 0
        hasRequests = requests != nil
        lastProbed = c.lenientString(forKey: .lastChecked) ?? c.lenientString(forKey: .lastProbed)
        self.status = status
        isActive = c.lenientBool(forKey: .isActive) ?? (status == "active" || status == "warning")
        percentUsed = c.lenientDouble(forKey: .percentUsed)
        sessionPercentUsed = c.lenientDouble(forKey: .sessionPercentUsed)
        weeklyPercentUsed = c.lenientDouble(forKey: .weeklyPercentUsed)
        errorMessage = c.lenientString(forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(planName, forKey: .planName)
        try c.encodeIfPresent(planLabel, forKey: .planLabel)
        if hasTokens { try c.encode(tokensUsed, forKey: .tokensUsed) }
        try c.encodeIfPresent(tokensLimit, forKey: .tokensLimit)
        if hasCost { try c.encode(costUsed, forKey: .costUsed) }
        try c.encodeIfPresent(costLimit, forKey: .costLimit)
        if hasRequests { try c.encode(requestsCount, forKey: .requestsCount) }
        try c.encodeIfPresent(lastProbed, forKey: .lastProbed)
        try c.encode(isActive, forKey: .isActive)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(percentUsed, forKey: .percentUsed)
        try c.encodeIfPresent(sessionPercentUsed, forKey: .sessionPercentUsed)
        try c.encodeIfPresent(weeklyPercentUsed, forKey: .weeklyPercentUsed)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

    static func decodeList(from data: Data) throws -> [UsageAccount] {
        try HubList.decode(UsageAccount.self, from: data).items
    }
}

/// GET /api/mobile/status. The hub sends app, status, endpoints, bind_mode,
/// transport_label, resolved_transport and iroh. It sends no service or
/// version, so those stay as defaults for the code that reads them.
struct MobileStatus: Codable, Equatable {
    let status: String
    let service: String
    let version: String
    let pairedAgentsOnline: Int?
    let bindMode: String?
    let transportLabel: String?
    let resolvedTransport: String?

    init(status: String, service: String, version: String, pairedAgentsOnline: Int? = nil,
         bindMode: String? = nil, transportLabel: String? = nil, resolvedTransport: String? = nil) {
        self.status = status
        self.service = service
        self.version = version
        self.pairedAgentsOnline = pairedAgentsOnline
        self.bindMode = bindMode
        self.transportLabel = transportLabel
        self.resolvedTransport = resolvedTransport
    }

    private enum CodingKeys: String, CodingKey {
        case status, app, service, version, pairedAgentsOnline
        case bindMode, transportLabel, resolvedTransport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenientString(forKey: .status) ?? "unknown"
        service = c.lenientString(forKey: .service) ?? c.lenientString(forKey: .app) ?? "AgnView"
        version = c.lenientString(forKey: .version) ?? ""
        pairedAgentsOnline = c.lenientInt(forKey: .pairedAgentsOnline)
        bindMode = c.lenientString(forKey: .bindMode)
        transportLabel = c.lenientString(forKey: .transportLabel)
        resolvedTransport = c.lenientString(forKey: .resolvedTransport)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(service, forKey: .service)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(pairedAgentsOnline, forKey: .pairedAgentsOnline)
        try c.encodeIfPresent(bindMode, forKey: .bindMode)
        try c.encodeIfPresent(transportLabel, forKey: .transportLabel)
        try c.encodeIfPresent(resolvedTransport, forKey: .resolvedTransport)
    }

    static func decode(from data: Data) throws -> MobileStatus {
        try HubJSON.decode(MobileStatus.self, from: data)
    }
}
