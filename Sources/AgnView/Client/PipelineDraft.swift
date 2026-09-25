import Foundation

/// One task in the New pipeline form.
struct TaskDraft: Equatable, Identifiable {
    /// Stays the same while the person edits the task id, so prerequisites keep their links.
    let id: UUID
    var taskId: String
    var title: String
    var description: String
    var agent: String
    /// The tasks this one waits for, by draft identity.
    var prerequisites: Set<UUID>
    /// Per-task model and effort. Drawn only when HubFeatures.supportsTaskModelEffort
    /// is on, and not sent in phase A.
    var modelId: String
    var effortId: String

    init(id: UUID = UUID(), taskId: String, title: String = "", description: String = "",
         agent: String = PipelineDraft.agents[0].id, prerequisites: Set<UUID> = [],
         modelId: String = "", effortId: String = "") {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.description = description
        self.agent = agent
        self.prerequisites = prerequisites
        self.modelId = modelId
        self.effortId = effortId
    }
}

/// A reason the form cannot be sent yet.
enum PipelineIssue: Equatable {
    case titleRequired
    case noTasks
    case pipelineIdInvalid
    case taskTitleRequired(taskId: String)
    case taskIdInvalid(taskId: String)
    case taskIdDuplicate(taskId: String)
    case dependencyCycle(taskIds: [String])

    var message: String {
        switch self {
        case .titleRequired: return "Title is required."
        case .noTasks: return "Add at least one task."
        case .pipelineIdInvalid:
            return "The pipeline ID can use letters, digits, dot, dash and underscore only."
        case .taskTitleRequired(let id): return "Task \(id) needs a title."
        case .taskIdInvalid(let id):
            return "Task ID \"\(id)\" is not valid. Use letters, digits, dot, dash and underscore."
        case .taskIdDuplicate(let id): return "Two tasks use the ID \(id)."
        case .dependencyCycle(let ids):
            return "These tasks wait for each other: " + ids.joined(separator: ", ") + "."
        }
    }
}

/// The POST /api/jobs body: {id?, title, description, tasks[id, title,
/// description, assigned_agent, dependencies]}.
struct CreateJobBody: Encodable, Equatable {
    struct TaskBody: Encodable, Equatable {
        var id: String
        var title: String
        var description: String
        var assignedAgent: String
        var dependencies: [String]

        private enum CodingKeys: String, CodingKey {
            case id, title, description, dependencies
            case assignedAgent = "assigned_agent"
        }
    }

    var id: String?
    var title: String
    var description: String
    var tasks: [TaskBody]

    private enum CodingKeys: String, CodingKey { case id, title, description, tasks }

    /// The id is left out when empty, so the hub picks one.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(tasks, forKey: .tasks)
    }
}

/// The New pipeline form as data: validation, the request body and the
/// dependency check, all testable without a screen.
struct PipelineDraft: Equatable {
    struct AgentChoice: Equatable, Identifiable {
        let id: String
        let name: String
    }

    /// The agents a task can be assigned to.
    static let agents: [AgentChoice] = [
        AgentChoice(id: "claude_code", name: "Claude Code"),
        AgentChoice(id: "codex", name: "Codex"),
        AgentChoice(id: "antigravity", name: "AntiGravity"),
        AgentChoice(id: "custom", name: "Custom"),
    ]

    var jobId = ""
    var title = ""
    var description = ""
    var tasks: [TaskDraft]
    var attachments: [AttachmentItem] = []
    /// Makes default task ids unique across pipelines: the hub keys tasks by id.
    let idSeed: String

    init(idSeed: String = PipelineDraft.randomSeed()) {
        self.idSeed = idSeed
        self.tasks = []
        addTask()
    }

    static func randomSeed() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
    }

    /// Safe for a URL path segment, which is how the hub addresses jobs and tasks.
    static func isSafeId(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    // MARK: Editing

    mutating func addTask() {
        var number = tasks.count + 1
        var candidate = "task-\(idSeed)-\(number)"
        while tasks.contains(where: { $0.taskId == candidate }) {
            number += 1
            candidate = "task-\(idSeed)-\(number)"
        }
        tasks.append(TaskDraft(taskId: candidate))
    }

    /// Removes a task and every prerequisite link that pointed at it.
    mutating func removeTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        for index in tasks.indices { tasks[index].prerequisites.remove(id) }
    }

    /// The tasks another task may wait for: every other task.
    func prerequisiteChoices(for id: UUID) -> [TaskDraft] {
        tasks.filter { $0.id != id }
    }

    // MARK: Validation

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    func issues() -> [PipelineIssue] {
        var found: [PipelineIssue] = []
        if trimmedTitle.isEmpty { found.append(.titleRequired) }
        let idText = jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !idText.isEmpty, !PipelineDraft.isSafeId(idText) { found.append(.pipelineIdInvalid) }
        if tasks.isEmpty { found.append(.noTasks) }
        var seen = Set<String>()
        var reported = Set<String>()
        for task in tasks {
            let id = task.taskId.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || !PipelineDraft.isSafeId(id) {
                found.append(.taskIdInvalid(taskId: id))
            } else if !seen.insert(id).inserted, reported.insert(id).inserted {
                found.append(.taskIdDuplicate(taskId: id))
            }
            if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(.taskTitleRequired(taskId: id.isEmpty ? "(no id)" : id))
            }
        }
        if let cycle = dependencyCycle() { found.append(.dependencyCycle(taskIds: cycle)) }
        return found
    }

    var isValid: Bool { issues().isEmpty }

    /// The task ids on a dependency cycle, or nil when there is none.
    func dependencyCycle() -> [String]? {
        var graph: [String: [String]] = [:]
        let names = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskId.trimmingCharacters(in: .whitespacesAndNewlines)) })
        for task in tasks {
            let name = names[task.id] ?? task.taskId
            let deps = task.prerequisites.compactMap { names[$0] }.sorted()
            graph[name, default: []].append(contentsOf: deps)
        }
        return DependencyGraph.cycle(in: graph)
    }

    // MARK: Request

    /// The body for POST /api/jobs. Hub files become a "[Context Files: ...]"
    /// line at the end of every task description, as a dispatch does.
    func requestBody() -> CreateJobBody {
        let names = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.taskId.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let idText = jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateJobBody(
            id: idText.isEmpty ? nil : idText,
            title: trimmedTitle,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            tasks: tasks.map { task in
                CreateJobBody.TaskBody(
                    id: names[task.id] ?? task.taskId,
                    title: task.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: Attachments.embed(attachments, in: task.description),
                    assignedAgent: task.agent,
                    dependencies: task.prerequisites.compactMap { names[$0] }.sorted())
            })
    }

    /// True when anything was typed, so Cancel can ask before it discards.
    var isDirty: Bool {
        !jobId.isEmpty || !title.isEmpty || !description.isEmpty || !attachments.isEmpty
            || tasks.count > 1
            || tasks.contains { !$0.title.isEmpty || !$0.description.isEmpty || !$0.prerequisites.isEmpty }
    }
}

enum DependencyGraph {
    /// One cycle in a graph of task id to prerequisite ids, or nil. Ids that
    /// are not keys in the graph are ignored.
    static func cycle(in graph: [String: [String]]) -> [String]? {
        enum Mark { case visiting, done }
        var marks: [String: Mark] = [:]
        var stack: [String] = []

        func visit(_ node: String) -> [String]? {
            marks[node] = .visiting
            stack.append(node)
            for next in graph[node] ?? [] where graph[next] != nil {
                if marks[next] == .visiting {
                    let start = stack.firstIndex(of: next) ?? 0
                    return Array(stack[start...])
                }
                if marks[next] == nil, let found = visit(next) { return found }
            }
            stack.removeLast()
            marks[node] = .done
            return nil
        }

        for node in graph.keys.sorted() where marks[node] == nil {
            if let found = visit(node) { return found }
        }
        return nil
    }
}
