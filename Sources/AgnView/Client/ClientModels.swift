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
        guard let id = c.lenientString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "task id"))
        }
        self.id = id
        jobId = c.lenientString(forKey: .jobId)
        title = c.lenientString(forKey: .title) ?? ""
        description = c.lenientString(forKey: .description)
        assignedAgent = c.lenientString(forKey: .assignedAgent)
        status = (try? c.decodeIfPresent(TaskStatus.self, forKey: .status)) ?? .unknown("")
        dependencies = c.lenientStrings(forKey: .dependencies)
        outputSummary = c.lenientString(forKey: .outputSummary)
    }
}

/// A multi-agent pipeline (GET /api/jobs). The hub sends `tasks` as an object
/// keyed by task id. An array is accepted as well.
struct Job: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: JobStatus
    let createdAt: String?
    let updatedAt: String?
    let tasks: [PipelineTask]
    /// Tasks the hub sent that could not be read and were left out.
    let droppedTasks: Int

    init(id: String, title: String, description: String? = nil, status: JobStatus,
         createdAt: String? = nil, updatedAt: String? = nil, tasks: [PipelineTask] = [],
         droppedTasks: Int = 0) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tasks = tasks
        self.droppedTasks = droppedTasks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, createdAt, updatedAt, tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath,
                                                                 debugDescription: "job id"))
        }
        self.id = id
        title = c.lenientString(forKey: .title) ?? ""
        description = c.lenientString(forKey: .description)
        status = (try? c.decodeIfPresent(JobStatus.self, forKey: .status)) ?? .unknown("")
        createdAt = c.lenientString(forKey: .createdAt)
        updatedAt = c.lenientString(forKey: .updatedAt)
        if let list = try? c.decode(LenientList<PipelineTask>.self, forKey: .tasks) {
            tasks = list.items
            droppedTasks = list.dropped
        } else if let map = try? c.decode([String: Failable<PipelineTask>].self, forKey: .tasks) {
            let good = map.values.compactMap { $0.value }
            tasks = Job.ordered(good)
            droppedTasks = map.count - good.count
        } else {
            tasks = []
            droppedTasks = 0
        }
    }

    /// Dependencies first, then by id, so the list reads in pipeline order.
    static func ordered(_ tasks: [PipelineTask]) -> [PipelineTask] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func depthOf(_ id: String, _ path: Set<String>) -> Int {
            guard let task = byId[id], !path.contains(id) else { return 0 }
            return task.dependencies.map { depthOf($0, path.union([id])) + 1 }.max() ?? 0
        }
        return tasks.sorted { left, right in
            let l = depthOf(left.id, []), r = depthOf(right.id, [])
            return l != r ? l < r : left.id < right.id
        }
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
        case agent, sessionId, cliSessionId, workingDirectory, busy, idleSeconds, pid
    }

    /// The hub sends session_id as null for a process it started without a
    /// console conversation. Fall back to the CLI id, the pid, then agent and directory.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let agentText = c.lenientString(forKey: .agent)
        let dirText = c.lenientString(forKey: .workingDirectory)
        agent = agentText
        workingDirectory = dirText
        let primary = c.lenientString(forKey: .sessionId).flatMap { $0.isEmpty ? nil : $0 }
        let cli = c.lenientString(forKey: .cliSessionId).flatMap { $0.isEmpty ? nil : $0 }
        let pid = c.lenientString(forKey: .pid).map { "pid-" + $0 }
        let composite = agentText.map { $0 + "@" + (dirText ?? "") }
        guard let sid = primary ?? cli ?? pid ?? composite else {
            throw DecodingError.keyNotFound(CodingKeys.sessionId, .init(codingPath: c.codingPath,
                                                                        debugDescription: "session id"))
        }
        sessionId = sid
        busy = c.lenientBool(forKey: .busy) ?? false
        idleSeconds = c.lenientDouble(forKey: .idleSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encode(busy, forKey: .busy)
        try c.encodeIfPresent(idleSeconds, forKey: .idleSeconds)
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
        // The hub reads agent and working_directory. It answers 422 to the
        // names the API document used (target_agent, working_dir).
        case targetAgent = "agent"
        case prompt
        case workingDir = "working_directory"
        case sessionId = "session_id"
    }

    /// Encodes nil optionals as JSON null, which the hub accepts for both.
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
        status = c.lenientString(forKey: .status)
        agent = c.lenientString(forKey: .agent)
        sessionId = c.lenientString(forKey: .sessionId)
        message = c.lenientString(forKey: .message)
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
            HubLog.decodeFailure(type, error)
            throw TransportError.protocolViolation
        }
    }
}
