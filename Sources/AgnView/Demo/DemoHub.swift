import Foundation

/// One task in a demo pipeline.
struct DemoTask: Equatable {
    var id: String
    var title: String
    var description: String
    var agent: String
    var status: String
    var dependencies: [String]
    var summary: String?
}

/// One demo pipeline. Its status follows from its tasks.
struct DemoJob: Equatable {
    var id: String
    var title: String
    var description: String
    var createdAt: String
    var tasks: [DemoTask]

    var status: String {
        if tasks.isEmpty { return "pending" }
        if tasks.contains(where: { $0.status == "failed" }) { return "failed" }
        if tasks.allSatisfy({ $0.status == "completed" }) { return "completed" }
        if tasks.contains(where: { $0.status == "revision_requested" }) { return "revision_in_progress" }
        if tasks.contains(where: { $0.status == "in_progress" }) { return "in_progress" }
        return "pending"
    }
}

/// The built-in hub for demo mode. It answers the same calls as a real hub
/// (the APITransport seam) from sample data held in memory, and it feeds a
/// console stream (the HubSession seam). It never opens a socket, never
/// touches the Keychain and never writes a file. Pipelines created or deleted
/// here live in memory until the demo ends.
final class DemoHub: APITransport, @unchecked Sendable {
    private struct Row {
        let id: Int
        let agent: String
        let source: String
        let content: String
        let timestamp: String
        let sessionId: String?
    }

    private let lock = NSLock()
    private let now: () -> Date
    private let replyDelay: TimeInterval

    private var rows: [Row] = []
    private var jobs: [DemoJob] = []
    private var busyAgents: Set<String> = ["claude_code"]
    private var refreshedAt: Date?
    private var nextJobNumber = 1
    private var sink: ((ConsoleFrame) -> Void)?

    /// `replyDelay` is the pause before the canned reply to a prompt. Zero
    /// answers at once, which the tests use.
    init(now: @escaping () -> Date = { Date() }, replyDelay: TimeInterval = 0.8) {
        self.now = now
        self.replyDelay = replyDelay
        let start = now().addingTimeInterval(-Double(DemoData.backlog.count) * 20)
        for (index, line) in DemoData.backlog.enumerated() {
            rows.append(Row(id: index + 1, agent: line.agent, source: line.source, content: line.content,
                            timestamp: DemoHub.iso(start.addingTimeInterval(Double(index) * 20)),
                            sessionId: line.session))
        }
        jobs = DemoHub.sampleJobs(at: DemoHub.iso(now().addingTimeInterval(-3600)))
    }

    // MARK: Session

    /// A console session on this hub. `interval` is the pause between live lines.
    func makeSession(interval: TimeInterval = 4) -> DemoHubSession {
        DemoHubSession(hub: self, interval: interval)
    }

    /// Sends every line so far to `sink`, then every new line. One sink at a time.
    func attach(sink: @escaping (ConsoleFrame) -> Void) {
        lock.lock()
        for row in rows { sink(.log(Self.entry(row))) }
        self.sink = sink
        lock.unlock()
    }

    func detach() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    /// Adds one line to the console and sends it to the attached session.
    func appendRow(agent: String, source: String, content: String, sessionId: String?) {
        lock.lock()
        let row = Row(id: (rows.last?.id ?? 0) + 1, agent: agent, source: source, content: content,
                      timestamp: Self.iso(now()), sessionId: sessionId)
        rows.append(row)
        let target = sink
        lock.unlock()
        target?(.log(Self.entry(row)))
    }

    /// The console lines so far.
    var consoleEntries: [ConsoleFrame.LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return rows.map(Self.entry)
    }

    /// The pipelines so far.
    var pipelines: [DemoJob] {
        lock.lock()
        defer { lock.unlock() }
        return jobs
    }

    private static func entry(_ row: Row) -> ConsoleFrame.LogEntry {
        ConsoleFrame.LogEntry(id: row.id, agent: row.agent, source: row.source, content: row.content,
                              timestamp: row.timestamp, sessionId: row.sessionId)
    }

    // MARK: APITransport

    func send(method: String, path: String, body: Data?) async throws -> APIResponse {
        let (route, query) = Self.split(path)
        switch (method.uppercased(), route) {
        case ("GET", HubPath.status):
            return Self.ok(["app": "AgnView Demo", "status": "demo", "bind_mode": "demo",
                            "transport_label": "Demo", "resolved_transport": "lan"])
        case ("GET", HubPath.usageAccounts):
            return Self.ok(usageAccounts())
        case ("POST", HubPath.usageRefreshAll):
            markRefreshed()
            return Self.ok(usageAccounts())
        case ("GET", HubPath.liveSessions):
            return Self.ok(liveSessions())
        case ("GET", HubPath.consoleLogs):
            return Self.ok(logs(query: query))
        case ("GET", HubPath.capabilities):
            return Self.ok(capabilitiesBody())
        case ("GET", HubPath.files):
            let listing: [String: Any] = ["files": DemoData.files, "cwd": DemoData.workingDirectory]
            return Self.ok(listing)
        case ("GET", HubPath.jobs):
            return Self.ok(jobsBody())
        case ("POST", HubPath.dispatch):
            return dispatch(body)
        case ("POST", HubPath.jobs):
            return createJob(body)
        default:
            break
        }
        let parts = route.split(separator: "/").map(String.init)
        if method.uppercased() == "DELETE", parts.count == 3, parts[0] == "api", parts[1] == "jobs" {
            return deleteJob(id: parts[2])
        }
        if method.uppercased() == "POST", parts.count == 4, parts[0] == "api", parts[1] == "tasks" {
            switch parts[3] {
            case "request-revision": return changeTask(id: parts[2], status: "revision_requested", body: body)
            case "fail": return changeTask(id: parts[2], status: "failed", body: body)
            default: break
            }
        }
        return Self.failure(404, "Not found.")
    }

    // MARK: Answers

    private func markRefreshed() {
        lock.lock()
        refreshedAt = now()
        lock.unlock()
    }

    private func jobsBody() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.map(Self.jobBody)
    }

    private func dispatch(_ body: Data?) -> APIResponse {
        guard let object = Self.object(body),
              let prompt = (object["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return Self.failure(422, "A prompt is required.")
        }
        let agent = (object["agent"] as? String) ?? "claude_code"
        let requested = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let session = requested ?? DemoData.session(for: agent)
        let files = (object["files"] as? [String]) ?? []
        lock.lock()
        busyAgents.insert(agent)
        lock.unlock()
        appendRow(agent: "user", source: "user_input", content: prompt, sessionId: session)
        if replyDelay <= 0 {
            reply(agent: agent, prompt: prompt, session: session, files: files)
        } else {
            let delay = UInt64(replyDelay * 1_000_000_000)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.reply(agent: agent, prompt: prompt, session: session, files: files)
            }
        }
        return Self.ok(["status": "dispatched", "agent": agent, "session_id": session,
                        "message": "Demo mode. Sent to the sample console only."])
    }

    /// The canned answer to a prompt. It says plainly that no agent ran.
    private func reply(agent: String, prompt: String, session: String, files: [String]) {
        appendRow(agent: agent, source: "agent_stdout",
                  content: "Demo reply. This answer is built in. No real agent ran.", sessionId: session)
        let shown = prompt.count > 80 ? String(prompt.prefix(80)) + "..." : prompt
        appendRow(agent: agent, source: "agent_stdout", content: "Your prompt was: " + shown, sessionId: session)
        if !files.isEmpty {
            appendRow(agent: agent, source: "agent_stdout",
                      content: "Attached: " + files.joined(separator: ", "), sessionId: session)
        }
        appendRow(agent: "system", source: "system_notice", content: "Finished", sessionId: session)
        lock.lock()
        busyAgents.remove(agent)
        lock.unlock()
    }

    private func createJob(_ body: Data?) -> APIResponse {
        guard let object = Self.object(body) else { return Self.failure(422, "The request body is not readable.") }
        let title = ((object["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return Self.failure(422, "A title is required.") }
        guard let rawTasks = object["tasks"] as? [[String: Any]], !rawTasks.isEmpty else {
            return Self.failure(422, "A pipeline needs at least one task.")
        }
        var tasks: [DemoTask] = []
        for raw in rawTasks {
            let id = ((raw["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard PipelineDraft.isSafeId(id) else { return Self.failure(422, "A task id is not valid.") }
            if tasks.contains(where: { $0.id == id }) {
                return Self.failure(422, "Task id \(id) is used twice.")
            }
            let taskTitle = ((raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if taskTitle.isEmpty { return Self.failure(422, "Task \(id) needs a title.") }
            tasks.append(DemoTask(id: id, title: taskTitle,
                                  description: (raw["description"] as? String) ?? "",
                                  agent: (raw["assigned_agent"] as? String) ?? "claude_code",
                                  status: "pending",
                                  dependencies: (raw["dependencies"] as? [String]) ?? [],
                                  summary: nil))
        }
        let known = Set(tasks.map { $0.id })
        for task in tasks {
            if task.dependencies.contains(task.id) || !Set(task.dependencies).isSubset(of: known) {
                return Self.failure(422, "Task \(task.id) waits for a task that does not exist.")
            }
        }
        for index in tasks.indices where tasks[index].dependencies.isEmpty { tasks[index].status = "ready" }
        lock.lock()
        defer { lock.unlock() }
        var id = ((object["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            repeat {
                id = "job-demo-\(nextJobNumber)"
                nextJobNumber += 1
            } while jobs.contains(where: { $0.id == id })
        } else if !PipelineDraft.isSafeId(id) {
            return Self.failure(422, "The pipeline id is not valid.")
        } else if jobs.contains(where: { $0.id == id }) {
            return Self.failure(409, "A pipeline with this id already exists.")
        }
        let job = DemoJob(id: id, title: title,
                          description: ((object["description"] as? String) ?? ""),
                          createdAt: Self.iso(now()), tasks: tasks)
        jobs.append(job)
        return Self.ok(Self.jobBody(job))
    }

    private func deleteJob(id: String) -> APIResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return Self.failure(404, "That pipeline does not exist.")
        }
        jobs.remove(at: index)
        return Self.ok(["status": "deleted", "id": id])
    }

    private func changeTask(id: String, status: String, body: Data?) -> APIResponse {
        let object = Self.object(body) ?? [:]
        let note = ((object["feedback"] as? String) ?? (object["reason"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "failed", note.isEmpty { return Self.failure(422, "A reason is required.") }
        lock.lock()
        defer { lock.unlock() }
        for jobIndex in jobs.indices {
            if let taskIndex = jobs[jobIndex].tasks.firstIndex(where: { $0.id == id }) {
                jobs[jobIndex].tasks[taskIndex].status = status
                if !note.isEmpty { jobs[jobIndex].tasks[taskIndex].summary = note }
                return Self.ok(["status": status, "id": id])
            }
        }
        return Self.failure(404, "That task does not exist.")
    }

    private func liveSessions() -> [[String: Any]] {
        lock.lock()
        let busy = busyAgents
        lock.unlock()
        let list: [(String, String, Double)] = [
            ("claude_code", DemoData.claudeSession, 2.5),
            ("codex", DemoData.codexSession, 95),
            ("antigravity", DemoData.antigravitySession, 410),
        ]
        return list.map { agent, session, idle in
            let isBusy = busy.contains(agent)
            let item: [String: Any] = ["agent": agent, "session_id": session,
                                       "working_directory": DemoData.workingDirectory,
                                       "busy": isBusy, "alive": true, "idle_seconds": isBusy ? 0.0 : idle]
            return item
        }
    }

    private func logs(query: [String: String]) -> [[String: Any]] {
        lock.lock()
        let all = rows
        lock.unlock()
        let limit = max(1, min(Int(query["limit"] ?? "") ?? 250, 1000))
        var picked = all
        if let after = query["after_id"].flatMap({ Int($0) }) {
            picked = Array(all.filter { $0.id > after }.prefix(limit))
        } else {
            picked = Array(all.suffix(limit))
        }
        return picked.map { row in
            var item: [String: Any] = ["id": row.id, "agent": row.agent, "source": row.source,
                                       "content": row.content, "timestamp": row.timestamp, "metadata": [String: Any]()]
            item["session_id"] = Self.orNull(row.sessionId)
            return item
        }
    }

    private func capabilitiesBody() -> [String: Any] {
        func list(_ source: [String: [(id: String, name: String)]]) -> [String: Any] {
            source.mapValues { $0.map { ["id": $0.id, "name": $0.name] } }
        }
        return [
            "installed_clis": [
                ["id": "claude_code", "name": "Claude Code", "available": true],
                ["id": "codex", "name": "Codex", "available": true],
                ["id": "antigravity", "name": "AntiGravity", "available": true],
            ],
            "models": list(DemoData.models),
            "efforts": ["low", "medium", "high"],
            "efforts_by_provider": list(DemoData.efforts),
            "current_cwd": DemoData.workingDirectory,
        ]
    }

    // MARK: Usage

    private func usageAccounts() -> [[String: Any]] {
        lock.lock()
        let refreshed = refreshedAt != nil
        lock.unlock()
        func age(_ seconds: Double) -> Double { refreshed ? 5 : seconds }
        func ageText(_ seconds: Double) -> String { refreshed ? "measured just now" : "measured \(Int(seconds / 60))m ago" }
        return [
            Self.account(
                id: "demo-claude", provider: "claude", name: "Demo Claude account", plan: "Demo plan",
                status: "active", tokens: 182_000, cost: 6.4, requests: 48,
                source: "Demo sample", ageSeconds: age(120), ageText: ageText(120), stale: false,
                sessionPercent: 62, weeklyPercent: 38,
                windows: [
                    Self.window(key: "session", label: "Five hour limit", percent: 62, reset: "Resets in 2h 05m",
                                active: true,
                                children: [
                                    Self.window(key: "session:large", label: "Large model", percent: 41, reset: nil),
                                    Self.window(key: "session:small", label: "Small model", percent: 21, reset: nil),
                                ]),
                    Self.window(key: "weekly", label: "Weekly limit", percent: 38, reset: "Resets in 3d 4h"),
                ]),
            Self.account(
                id: "demo-codex", provider: "chatgpt", name: "Demo Codex account", plan: "Demo plan",
                status: "active", tokens: 96_000, cost: 3.1, requests: 27,
                source: "Demo sample", ageSeconds: age(300), ageText: ageText(300), stale: false,
                sessionPercent: 24, weeklyPercent: 71,
                windows: [
                    Self.window(key: "session", label: "Five hour limit", percent: 24, reset: "Resets in 3h 40m"),
                    Self.window(key: "weekly", label: "Weekly limit", percent: 71, reset: "Resets in 1d 9h",
                                active: true),
                ]),
            Self.account(
                id: "demo-antigravity", provider: "antigravity", name: "Demo AntiGravity account", plan: "Demo plan",
                status: "warning", tokens: 240_000, cost: 8.9, requests: 63,
                source: "Demo sample", ageSeconds: age(180), ageText: ageText(180), stale: false,
                sessionPercent: 91, weeklyPercent: 48,
                windows: [
                    Self.window(key: "session", label: "Five hour limit", percent: 91, reset: "Resets in 1h 12m",
                                active: true, severity: "warning",
                                children: [
                                    Self.window(key: "session:pro", label: "Pro models", percent: 74, reset: nil),
                                    Self.window(key: "session:flash", label: "Flash models", percent: 17, reset: nil),
                                ]),
                    Self.window(key: "weekly", label: "Weekly limit", percent: 48, reset: "Resets in 4d 2h"),
                ]),
            Self.account(
                id: "demo-gemini", provider: "gemini", name: "Demo Gemini account", plan: "Demo plan",
                status: "active", tokens: 31_000, cost: 0.9, requests: 9,
                source: "Demo sample", ageSeconds: 21_600, ageText: "measured 6h ago", stale: true,
                sessionPercent: 15, weeklyPercent: 9,
                windows: [
                    Self.window(key: "session", label: "Daily limit", percent: 15, reset: "Resets in 9h 30m"),
                ]),
        ]
    }

    private static func account(id: String, provider: String, name: String, plan: String, status: String,
                                tokens: Int, cost: Double, requests: Int, source: String,
                                ageSeconds: Double, ageText: String, stale: Bool,
                                sessionPercent: Double, weeklyPercent: Double,
                                windows: [[String: Any]]) -> [String: Any] {
        [
            "id": id, "provider": provider, "name": name, "plan_name": plan, "plan_label": plan,
            "status": status, "tokens_used": tokens, "cost_used_usd": cost, "requests_used": requests,
            "percent_used": sessionPercent, "session_percent_used": sessionPercent,
            "weekly_percent_used": weeklyPercent,
            "last_checked": iso(Date()), "error_message": NSNull(),
            "usage": [
                "source_label": source, "age_text": ageText, "age_seconds": ageSeconds, "is_stale": stale,
                "plan_name": plan, "plan_label": plan, "error": NSNull(), "windows": windows,
            ] as [String: Any],
        ]
    }

    private static func window(key: String, label: String, percent: Double, reset: String?,
                               active: Bool = false, severity: String? = nil,
                               children: [[String: Any]] = []) -> [String: Any] {
        var item: [String: Any] = [
            "key": key, "label": label, "unit": "percent",
            "amount_text": String(format: "%.0f%% used", percent),
            "percent_used": percent, "has_bar": true, "is_active": active,
            "countdown_text": orNull(reset), "breakdown": children,
        ]
        if let severity { item["severity"] = severity }
        return item
    }

    // MARK: Pipelines

    private static func sampleJobs(at created: String) -> [DemoJob] {
        [
            DemoJob(id: "job-demo-signup", title: "Signup form checks",
                    description: "Sample pipeline with three tasks.", createdAt: created,
                    tasks: [
                        DemoTask(id: "add-checks", title: "Add input checks",
                                 description: "Check the email and display name fields.",
                                 agent: "claude_code", status: "completed", dependencies: [],
                                 summary: "Added checks for both fields. 14 tests pass."),
                        DemoTask(id: "review-edges", title: "Review edge cases",
                                 description: "List inputs the checks miss.",
                                 agent: "codex", status: "in_progress", dependencies: ["add-checks"],
                                 summary: nil),
                        DemoTask(id: "update-docs", title: "Update the sample docs",
                                 description: "Describe the new checks.",
                                 agent: "antigravity", status: "pending", dependencies: ["review-edges"],
                                 summary: nil),
                    ]),
            DemoJob(id: "job-demo-report", title: "Weekly usage report",
                    description: "Collect the figures, then write a short summary.", createdAt: created,
                    tasks: [
                        DemoTask(id: "collect-figures", title: "Collect the figures",
                                 description: "Read the usage numbers for the week.",
                                 agent: "codex", status: "ready", dependencies: [], summary: nil),
                        DemoTask(id: "write-summary", title: "Write the summary",
                                 description: "Two short paragraphs.",
                                 agent: "claude_code", status: "pending", dependencies: ["collect-figures"],
                                 summary: nil),
                    ]),
            DemoJob(id: "job-demo-docs", title: "Refresh the sample docs",
                    description: "A finished pipeline, for reference.", createdAt: created,
                    tasks: [
                        DemoTask(id: "draft-docs", title: "Draft the new sections",
                                 description: "Write the usage and pairing sections.",
                                 agent: "antigravity", status: "completed", dependencies: [],
                                 summary: "Drafted both sections."),
                        DemoTask(id: "check-links", title: "Check the links",
                                 description: "Open every link in the docs.",
                                 agent: "codex", status: "completed", dependencies: ["draft-docs"],
                                 summary: "All links work."),
                    ]),
        ]
    }

    private static func jobBody(_ job: DemoJob) -> [String: Any] {
        var map: [String: Any] = [:]
        for task in job.tasks {
            map[task.id] = [
                "id": task.id, "job_id": job.id, "title": task.title, "description": task.description,
                "assigned_agent": task.agent, "dependencies": task.dependencies, "status": task.status,
                "output_summary": orNull(task.summary),
            ] as [String: Any]
        }
        return ["id": job.id, "title": job.title, "description": job.description, "status": job.status,
                "created_at": job.createdAt, "updated_at": job.createdAt, "tasks": map]
    }

    // MARK: Helpers

    private static func orNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func split(_ path: String) -> (String, [String: String]) {
        guard let mark = path.firstIndex(of: "?") else { return (path, [:]) }
        var query: [String: String] = [:]
        for pair in path[path.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return (String(path[..<mark]), query)
    }

    private static func object(_ body: Data?) -> [String: Any]? {
        guard let body, !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func ok(_ value: Any) -> APIResponse {
        APIResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
    }

    private static func failure(_ status: Int, _ detail: String) -> APIResponse {
        APIResponse(status: status,
                    body: (try? JSONSerialization.data(withJSONObject: ["detail": detail])) ?? Data())
    }
}

/// The console stream of a demo hub. It replays the lines already there, then
/// adds a line every few seconds and answers prompts. Between lines it sends a
/// ping, so the connection watchdog stays quiet.
final class DemoHubSession: HubSession {
    let route: TransportRoute = .lan
    let capabilities: Set<Capability> = .lan
    let frames: AsyncThrowingStream<ConsoleFrame, Error>
    let api: APITransport?

    private let hub: DemoHub
    private let continuation: AsyncThrowingStream<ConsoleFrame, Error>.Continuation
    private let lock = NSLock()
    private var timeline: Task<Void, Never>?

    init(hub: DemoHub, interval: TimeInterval) {
        var captured: AsyncThrowingStream<ConsoleFrame, Error>.Continuation!
        frames = AsyncThrowingStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        self.hub = hub
        api = hub
        let stream = captured!
        stream.yield(.hello(ConsoleFrame.Hello(app: "AgnView Demo", protocolVersion: 1, hostname: nil,
                                               transport: "lan", capabilities: ["console", "api", "uploads"])))
        hub.attach { stream.yield($0) }
        let nanoseconds = UInt64(max(interval, 0.001) * 1_000_000_000)
        let task = Task { [weak hub] in
            var next = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { break }
                if next < DemoData.live.count {
                    let line = DemoData.live[next]
                    next += 1
                    hub?.appendRow(agent: line.agent, source: line.source, content: line.content,
                                   sessionId: line.session)
                } else {
                    stream.yield(.ping(transport: nil))
                }
            }
        }
        lock.lock()
        timeline = task
        lock.unlock()
        stream.onTermination = { [weak self] _ in self?.stop() }
    }

    private func stop() {
        lock.lock()
        let task = timeline
        timeline = nil
        lock.unlock()
        task?.cancel()
        hub.detach()
    }

    func close() async {
        stop()
        continuation.finish()
    }
}
