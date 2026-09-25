import Foundation

/// A string-backed enum that keeps unknown values instead of failing to decode,
/// so a newer hub never breaks an older app. Each conforming enum writes its
/// own Codable methods, which encode and decode the raw string.
protocol TolerantEnum: Codable, Equatable {
    init(raw: String)
    var raw: String { get }
}

enum Provider: TolerantEnum {
    case claude, chatgpt, gemini
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "claude": self = .claude
        case "chatgpt": self = .chatgpt
        case "gemini": self = .gemini
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .claude: return "claude"
        case .chatgpt: return "chatgpt"
        case .gemini: return "gemini"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension UsageAccount {
    var providerKind: Provider { Provider(raw: provider) }
}

enum AgentKind: TolerantEnum {
    case claudeCode, codex, antigravity, deepseek, custom
    case unknown(String)

    /// The agents a dispatch can target, in display order.
    static let dispatchable: [AgentKind] = [.claudeCode, .codex, .antigravity, .deepseek, .custom]

    init(raw: String) {
        switch raw {
        case "claude_code": self = .claudeCode
        case "codex": self = .codex
        case "antigravity": self = .antigravity
        case "deepseek": self = .deepseek
        case "custom": self = .custom
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .claudeCode: return "claude_code"
        case .codex: return "codex"
        case .antigravity: return "antigravity"
        case .deepseek: return "deepseek"
        case .custom: return "custom"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

enum JobStatus: TolerantEnum {
    case pending, inProgress, completed, revisionInProgress, failed
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "revision_in_progress": self = .revisionInProgress
        case "failed": self = .failed
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .pending: return "pending"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .revisionInProgress: return "revision_in_progress"
        case .failed: return "failed"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

enum TaskStatus: TolerantEnum {
    case pending, ready, inProgress, completed, revisionRequested, failed, blocked
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "pending": self = .pending
        case "ready": self = .ready
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "revision_requested": self = .revisionRequested
        case "failed": self = .failed
        case "blocked": self = .blocked
        default: self = .unknown(raw)
        }
    }

    var raw: String {
        switch self {
        case .pending: return "pending"
        case .ready: return "ready"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .revisionRequested: return "revision_requested"
        case .failed: return "failed"
        case .blocked: return "blocked"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// One task inside a pipeline. Named PipelineTask so it never clashes with
/// Swift concurrency's Task.
struct PipelineTask: Codable, Equatable, Identifiable {
    let id: String
    let jobId: String?
    let title: String
    let description: String?
    let assignedAgent: String?
    let status: TaskStatus
    let dependencies: [String]
    let outputSummary: String?

    init(id: String, jobId: String? = nil, title: String, description: String? = nil,
         assignedAgent: String? = nil, status: TaskStatus, dependencies: [String] = [],
         outputSummary: String? = nil) {
        self.id = id
        self.jobId = jobId
        self.title = title
        self.description = description
        self.assignedAgent = assignedAgent
        self.status = status
        self.dependencies = dependencies
        self.outputSummary = outputSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id, jobId, title, description, assignedAgent, status, dependencies, outputSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        assignedAgent = try c.decodeIfPresent(String.self, forKey: .assignedAgent)
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .unknown("")
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        outputSummary = try c.decodeIfPresent(String.self, forKey: .outputSummary)
    }
}

/// A multi-agent pipeline (GET /api/jobs).
struct Job: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: JobStatus
    let createdAt: String?
    let updatedAt: String?
    let tasks: [PipelineTask]

    init(id: String, title: String, description: String? = nil, status: JobStatus,
         createdAt: String? = nil, updatedAt: String? = nil, tasks: [PipelineTask] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, createdAt, updatedAt, tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        status = try c.decodeIfPresent(JobStatus.self, forKey: .status) ?? .unknown("")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        tasks = try c.decodeIfPresent([PipelineTask].self, forKey: .tasks) ?? []
    }
}

/// A CLI process the hub holds open (GET /api/console/live-sessions).
struct LiveSession: Codable, Equatable, Identifiable {
    let agent: String?
    let sessionId: String
    let workingDirectory: String?
    let busy: Bool
    let idleSeconds: Double?

    var id: String { sessionId }

    init(agent: String?, sessionId: String, workingDirectory: String? = nil,
         busy: Bool = false, idleSeconds: Double? = nil) {
        self.agent = agent
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.busy = busy
        self.idleSeconds = idleSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case agent, sessionId, workingDirectory, busy, idleSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        idleSeconds = try c.decodeIfPresent(Double.self, forKey: .idleSeconds)
    }
}

/// Body of POST /api/console/dispatch.
struct DispatchRequest: Codable, Equatable {
    var targetAgent: String
    var prompt: String
    var workingDir: String?
    var sessionId: String?

    init(targetAgent: String, prompt: String, workingDir: String? = nil, sessionId: String? = nil) {
        self.targetAgent = targetAgent
        self.prompt = prompt
        self.workingDir = workingDir
        self.sessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey {
        case targetAgent = "target_agent"
        case prompt
        case workingDir = "working_dir"
        case sessionId = "session_id"
    }

    /// Encodes nil optionals as JSON null, as the spec lists them nullable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetAgent, forKey: .targetAgent)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(workingDir, forKey: .workingDir)
        try c.encode(sessionId, forKey: .sessionId)
    }
}

/// Answer to a dispatch. Every field is optional because the spec leaves the
/// response body open.
struct DispatchResponse: Codable, Equatable {
    let status: String?
    let agent: String?
    let sessionId: String?
    let message: String?

    init(status: String? = nil, agent: String? = nil, sessionId: String? = nil, message: String? = nil) {
        self.status = status
        self.agent = agent
        self.sessionId = sessionId
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case status, agent, sessionId, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        agent = try? c.decodeIfPresent(String.self, forKey: .agent)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }
}

enum HubJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch {
            throw TransportError.protocolViolation
        }
    }
}
