import Foundation
import Combine

/// The pairing a connection attempt uses: a stored record plus its key.
struct PairedEndpoint: HubEndpoint {
    let record: HubRecord
    let key: Data

    var lanHost: String { record.lanHost }
    var lanPort: Int { record.lanPort }
    var irohTicket: String? { record.irohTicket }
    var isLoopbackLAN: Bool { record.lanHost == "127.0.0.1" }
}

/// One line in the console. `id` is the hub row id. A line the hub sent
/// without an id gets a negative local id.
struct ConsoleLine: Identifiable, Equatable {
    let id: Int
    let agent: String
    let source: String
    let content: String
    let timestamp: String?
    let sessionId: String?
}

/// A session row for the Sessions screen. `fromLog` is true when the app
/// derived the row from session_id on log frames instead of asking the hub.
struct SessionInfo: Identifiable, Equatable {
    let id: String
    var agent: String?
    var workingDirectory: String?
    var busy: Bool
    var idleSeconds: Double?
    var lastActivity: String?
    var lineCount: Int
    let fromLog: Bool
}

/// The last usage answer from the hub with the time the app took it.
struct UsageSnapshot: Equatable {
    let accounts: [UsageAccount]
    let takenAt: Date
}

enum PairingResult: Equatable {
    case idle
    case success(String)
    case failure(PairingError)
}

/// The single source of truth for the screens. It owns the hub store, runs
/// the connection ladder, reconnects with backoff and holds the data the
/// screens show. Views read the published properties and call the methods.
@MainActor
final class AppModel: ObservableObject {
    static let ringCapacity = 2000

    // MARK: Published state for the screens

    @Published private(set) var hubs: [HubRecord] = []
    @Published private(set) var activeHub: HubRecord?
    @Published private(set) var connection: ConnectionState = .connecting
    @Published private(set) var capabilities: Set<Capability> = []
    /// True when the ladder skipped LAN (loopback pairing) and iroh carries the session.
    @Published private(set) var relayOnly = false
    /// The console buffer with the agent filter applied.
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var agentFilter: String?
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var usageSnapshot: UsageSnapshot?
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var statusLine = "No hub connected"
    /// One state per panel. A failed read shows in its panel only.
    @Published private(set) var usageState: PanelState<UsageSnapshot> = .loading
    @Published private(set) var jobsState: PanelState<[Job]> = .loading
    @Published private(set) var sessionsState: PanelState<[SessionInfo]> = .loading
    /// The last console send. Nil before the first send.
    @Published private(set) var dispatchState: PanelState<DispatchResponse>?
    /// The model and effort lists from the hub. Empty until the hub answers,
    /// and always empty over iroh, where the hub offers no such call.
    @Published private(set) var catalogue: HubCatalogue = .empty
    /// What this build can use of the hub. Phase A: no phone uploads, no
    /// per-task model and effort.
    @Published var features: HubFeatures = .phaseA
    /// When the Sessions list was last read.
    @Published private(set) var sessionsUpdatedAt: Date?
    /// True while a usage refresh runs.
    @Published private(set) var usageRefreshing = false
    @Published var pairingResult: PairingResult = .idle
    /// A one-off message for the screens, such as the removal note.
    @Published var notice: String?

    // MARK: Derived state

    var route: Route {
        guard case .online(let route, _) = connection else { return .offline }
        switch route {
        case .lan: return .lan
        case .direct: return .direct
        case .relay: return .relay
        }
    }

    var canDispatch: Bool { connection.isOnline && capabilities.contains(.dispatch) }
    var usageIsLive: Bool { connection.isOnline && capabilities.contains(.usage) }
    var jobsAreLive: Bool { connection.isOnline && capabilities.contains(.jobs) }
    /// True when the sessions list comes from log frames, not from the hub.
    var sessionsAreDerived: Bool { !capabilities.contains(.sessions) }
    var usage: [UsageAccount] { usageSnapshot?.accounts ?? [] }
    /// Attaching files that live on the computer, and the model and effort menus.
    var canAttachFromComputer: Bool { connection.isOnline && capabilities.contains(.catalogue) }
    /// Creating and deleting pipelines.
    var canManageJobs: Bool { connection.isOnline && capabilities.contains(.manageJobs) }
    /// Reading a pipeline, sending a revision request or marking a task failed.
    var canActOnTasks: Bool { connection.isOnline && capabilities.contains(.jobs) }
    /// True when Refresh in Usage asks the hub to read the providers again.
    var canRefreshUsageOnHub: Bool { connection.isOnline && capabilities.contains(.usageRefresh) }
    /// Why creating a pipeline is not possible here, or nil when it is.
    var pipelineCreateNotice: String? {
        guard connection.isOnline, !capabilities.contains(.manageJobs) else { return nil }
        return capabilities.contains(.jobs) ? UserMessages.needsSameWiFi : UserMessages.hubNeedsUpdate
    }

    /// True when the session can call the hub API: on the LAN always, over
    /// iroh when the hub lists the "api" capability (0.1.12 or later).
    var hubServesAPI: Bool { capabilities.contains(.usage) }

    /// Why the LAN route is not in use while the session runs, or nil when
    /// LAN carries it, iroh carries the API too, or nothing is connected. A
    /// loopback pairing gives pairedWithoutLAN. A real LAN address that failed
    /// gives notOnSameNetwork. Both apply only to a hub without remote access.
    var lanUnavailableReason: LANUnavailableReason? {
        guard case .online(let route, _) = connection, route != .lan, !hubServesAPI else { return nil }
        return relayOnly ? .pairedWithoutLAN : .notOnSameNetwork
    }

    var usageNotice: String? {
        guard connection.isOnline, !capabilities.contains(.usage) else { return nil }
        return UserMessages.hubNeedsUpdate
    }

    var jobsNotice: String? {
        guard connection.isOnline, !capabilities.contains(.jobs) else { return nil }
        return UserMessages.hubNeedsUpdate
    }

    var dispatchNotice: String? {
        guard connection.isOnline, !canDispatch else { return nil }
        return UserMessages.hubNeedsUpdate
    }

    var sessionsNotice: String? {
        connection.isOnline && sessionsAreDerived ? UserMessages.sessionsFromLog : nil
    }

    /// The banner text for the current connection state, if any.
    var statusMessage: String? {
        switch connection {
        case .authFailed: return UserMessages.authFailed
        case .keyRevoked: return UserMessages.keyRevoked
        case .offline: return activeHub == nil ? nil : UserMessages.offlineHub
        case .online: return lanUnavailableReason.map(UserMessages.lanBanner)
        case .connecting: return nil
        }
    }

    // MARK: Private state

    private let store: HubStore
    private let clock: Clock
    private let now: () -> Date
    private let makeLadder: (HubEndpoint, Clock, Int?) -> ConnectionLadder
    private let makeClient: (HubEndpoint) -> HubClient

    private var buffer: [ConsoleLine] = []
    private var seenIds: Set<Int> = []
    private var derivedSessions: [String: SessionInfo] = [:]
    private var lastLogId: Int?
    private var syntheticId = 0

    private var runTask: Task<Void, Never>?
    private var generation = 0
    private var liveSession: HubSession?
    private var client: HubClient?
    private var started = false

    #if DEBUG
    var debugForcedState: String?
    var debugMockURL: URL?
    #endif

    // MARK: Setup

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AgnView", isDirectory: true)
    }

    nonisolated static func defaultLadder(_ endpoint: HubEndpoint, _ clock: Clock, _ afterId: Int?) -> ConnectionLadder {
        ConnectionLadder(endpoint: endpoint, clock: clock,
                         makeIroh: { endpoint, ticket in
                             IrohTransport(ticket: ticket, token: endpoint.token, afterId: afterId)
                         })
    }

    init(secrets: SecretStore = KeychainStore(),
         directory: URL = AppModel.defaultDirectory,
         clock: Clock = SystemClock(),
         now: @escaping () -> Date = { Date() },
         makeLadder: @escaping (HubEndpoint, Clock, Int?) -> ConnectionLadder = AppModel.defaultLadder,
         makeClient: @escaping (HubEndpoint) -> HubClient = { HubClient(endpoint: $0) }) {
        self.store = HubStore(secrets: secrets, directory: directory)
        self.clock = clock
        self.now = now
        self.makeLadder = makeLadder
        self.makeClient = makeClient
        syncFromStore()
    }

    /// The model the app uses. Debug builds read the test environment.
    static func forLaunch() -> AppModel {
        #if DEBUG
        if let model = debugLaunchModel() { return model }
        #endif
        return AppModel()
    }

    // MARK: Lifecycle

    /// Starts the connection to the active hub. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if let forced = debugForcedState, applyForcedState(forced) { return }
        if let url = debugMockURL, hubs.isEmpty { pairMockHub(url) }
        #endif
        startConnection()
    }

    /// Stops the connection and closes the session. The data stays.
    func stop() {
        runTask?.cancel()
        runTask = nil
        generation += 1
        if let old = liveSession {
            Task { await old.close() }
        }
        liveSession = nil
        client = nil
    }

    /// Connects again now and resets the backoff.
    func retry() {
        startConnection()
    }

    // MARK: Pairing and hubs

    func pair(text: String) {
        do {
            complete(pairing: try PairingParser.parse(text))
        } catch let error as PairingError {
            pairingResult = .failure(error)
        } catch {
            pairingResult = .failure(.malformedURL)
        }
    }

    func pair(url: URL) {
        switch PairingURLHandler().handle(url) {
        case .success(let payload): complete(pairing: payload)
        case .failure(let error): pairingResult = .failure(error)
        }
    }

    private func complete(pairing payload: PairingPayload) {
        do {
            let record = try store.add(payload: payload)
            store.setActive(record.id)
            syncFromStore()
            resetHubData()
            notice = nil
            pairingResult = .success(record.name)
            startConnection()
        } catch {
            pairingResult = .failure(.invalidKey)
        }
    }

    func switchTo(_ id: String) {
        guard id != activeHub?.id, hubs.contains(where: { $0.id == id }) else { return }
        store.setActive(id)
        syncFromStore()
        resetHubData()
        startConnection()
    }

    /// Removes the hub and its key from this phone. The key stays valid on the hub.
    func remove(_ id: String) {
        let wasActive = activeHub?.id == id
        do {
            try store.remove(id: id)
        } catch {
            return
        }
        syncFromStore()
        notice = UserMessages.removedFromPhone
        if wasActive {
            resetHubData()
            startConnection()
        }
    }

    // MARK: Console and data

    func setAgentFilter(_ agent: String?) {
        agentFilter = (agent?.isEmpty ?? true) ? nil : agent
        republishLines()
    }

    /// Sends a prompt. Throws DispatchUnavailable when the connection has no
    /// dispatch capability (iroh to a hub before 0.1.12). Model and effort are
    /// sent only when set. Files are paths on the hub computer.
    @discardableResult
    func dispatch(agent: String, prompt: String, workingDir: String? = nil,
                  sessionId: String? = nil, model: String? = nil, effort: String? = nil,
                  files: [String]? = nil) async throws -> DispatchResponse {
        guard canDispatch else {
            throw DispatchUnavailable(message: UserMessages.hubNeedsUpdate)
        }
        guard let client else { throw HubError.notConnected }
        let request = DispatchRequest(targetAgent: agent, prompt: prompt,
                                      workingDir: workingDir, sessionId: sessionId,
                                      model: model, effort: effort, files: files)
        let response: DispatchResponse
        do {
            response = try await client.dispatch(request)
        } catch {
            throw HubError.transport(TransportError.normalise(error))
        }
        Task { [weak self] in await self?.refreshSessions() }
        return response
    }

    /// Sends a prompt and records the result in dispatchState. Returns true on
    /// success. A failure shows inline in the composer and nowhere else.
    @discardableResult
    func send(agent: String, prompt: String, model: String? = nil, effort: String? = nil,
              files: [String]? = nil) async -> Bool {
        if case .loading = dispatchState { return false }
        dispatchState = .loading
        do {
            let response = try await dispatch(agent: agent, prompt: prompt, model: model,
                                              effort: effort, files: files)
            dispatchState = .loaded(response)
            return true
        } catch {
            dispatchState = .failed(error.localizedDescription)
            return false
        }
    }

    func clearDispatchResult() {
        if case .loading = dispatchState { return }
        dispatchState = nil
    }

    /// The failure message for a panel, or nil when the connection layer
    /// already handles the error (401 and the rate limit) and the panel keeps
    /// what it has. Never touches the connection state.
    private func panelFailure(_ error: Error, panel: String) -> String? {
        switch TransportError.normalise(error) {
        case .unauthorised, .rateLimited: return nil
        default: return PanelMessages.couldNotRead(panel)
        }
    }

    /// The Retry buttons: show loading again, then read once more.
    func retryUsage() async {
        usageState = usageState.retrying()
        await refreshUsage()
    }

    func retryJobs() async {
        jobsState = jobsState.retrying()
        await refreshJobs()
    }

    func retrySessions() async {
        sessionsState = sessionsState.retrying()
        await refreshSessions()
    }

    func refreshUsage() async {
        guard usageIsLive, let client else {
            if let snapshot = usageSnapshot { usageState = usageState.markedStale(since: snapshot.takenAt) }
            return
        }
        let gen = generation
        do {
            let accounts = try await client.usageAccounts()
            guard gen == generation else { return }
            let snapshot = UsageSnapshot(accounts: accounts, takenAt: now())
            usageSnapshot = snapshot
            usageState = .loaded(snapshot)
        } catch {
            guard gen == generation, let message = panelFailure(error, panel: "Usage") else { return }
            usageState = .failed(message)
        }
    }

    /// The Refresh button in Usage. When the hub allows it (LAN), the hub reads
    /// every provider again first. Otherwise, or when that fails, this only
    /// reads the accounts the hub already holds.
    func refreshUsageFromHub() async {
        guard !usageRefreshing else { return }
        usageRefreshing = true
        defer { usageRefreshing = false }
        if canRefreshUsageOnHub, let client {
            let gen = generation
            if let accounts = try? await client.refreshAllUsage(), gen == generation {
                let snapshot = UsageSnapshot(accounts: accounts, takenAt: now())
                usageSnapshot = snapshot
                usageState = .loaded(snapshot)
                return
            }
        }
        await refreshUsage()
    }

    func refreshJobs() async {
        guard jobsAreLive, let client else { return }
        let gen = generation
        do {
            let list = try await client.jobs()
            guard gen == generation else { return }
            jobs = list
            jobsState = .loaded(list)
        } catch {
            guard gen == generation, let message = panelFailure(error, panel: "Pipelines") else { return }
            jobsState = .failed(message)
        }
    }

    func refreshSessions() async {
        guard connection.isOnline, capabilities.contains(.sessions), let client else { return }
        let gen = generation
        do {
            let live = try await client.liveSessions()
            guard gen == generation else { return }
            let mapped = live.map {
                SessionInfo(id: $0.sessionId, agent: $0.agent, workingDirectory: $0.workingDirectory,
                            busy: $0.busy, idleSeconds: $0.idleSeconds, lastActivity: nil,
                            lineCount: 0, fromLog: false)
            }
            sessions = mapped
            sessionsState = .loaded(mapped)
            sessionsUpdatedAt = now()
        } catch {
            guard gen == generation, let message = panelFailure(error, panel: "Sessions") else { return }
            sessionsState = .failed(message)
        }
    }

    /// The Refresh button and pull to refresh in Sessions: read the newest log
    /// rows (which the log-derived sessions come from), then the live sessions.
    func refreshSessionsNow() async {
        await backfillLogs()
        await refreshSessions()
        if !capabilities.contains(.sessions), connection.isOnline { sessionsUpdatedAt = now() }
    }

    /// Reads the log rows the app has not seen yet and ingests them.
    private func backfillLogs() async {
        guard connection.isOnline, hubServesAPI, let client else { return }
        let gen = generation
        guard let rows = try? await client.logs(afterId: lastLogId), gen == generation else { return }
        for row in rows { ingest(row) }
    }

    // MARK: Composer catalogue, files and pipelines

    func refreshCatalogue() async {
        guard canAttachFromComputer, let client else {
            if !capabilities.contains(.catalogue) { catalogue = .empty }
            return
        }
        let gen = generation
        if let fresh = try? await client.capabilities(), gen == generation { catalogue = fresh }
    }

    /// The files on the computer that can be attached.
    func hubFiles() async throws -> [String] {
        guard canAttachFromComputer else { throw HubError.transport(.notSupported) }
        guard let client else { throw HubError.notConnected }
        do {
            return try await client.files().files
        } catch {
            throw HubError.transport(TransportError.normalise(error))
        }
    }

    /// Creates a pipeline, reads the list again and returns the new pipeline.
    /// A refusal by the hub comes back as HubRejection with its reason.
    func createPipeline(_ draft: PipelineDraft) async throws -> Job {
        guard canManageJobs else { throw HubError.transport(.notSupported) }
        guard let client else { throw HubError.notConnected }
        let job: Job
        do {
            job = try await client.createJob(draft.requestBody())
        } catch let rejection as HubRejection {
            throw rejection
        } catch {
            throw HubError.transport(TransportError.normalise(error))
        }
        await refreshJobs()
        return job
    }

    func deletePipeline(id: String) async throws {
        guard canManageJobs else { throw HubError.transport(.notSupported) }
        try await taskCall { client in try await client.deleteJob(id: id) }
    }

    func requestRevision(taskId: String, feedback: String) async throws {
        guard canActOnTasks else { throw HubError.transport(.notSupported) }
        try await taskCall { client in try await client.requestRevision(taskId: taskId, feedback: feedback) }
    }

    func failTask(taskId: String, reason: String) async throws {
        guard canActOnTasks else { throw HubError.transport(.notSupported) }
        try await taskCall { client in try await client.failTask(taskId: taskId, reason: reason) }
    }

    /// Runs a pipeline change, then reads the list again.
    private func taskCall(_ call: (HubClient) async throws -> Void) async throws {
        guard let client else { throw HubError.notConnected }
        do {
            try await call(client)
        } catch let rejection as HubRejection {
            throw rejection
        } catch {
            throw HubError.transport(TransportError.normalise(error))
        }
        await refreshJobs()
    }

    // MARK: Connection loop

    private func syncFromStore() {
        hubs = store.hubs
        activeHub = store.activeHubId.flatMap { id in store.hubs.first { $0.id == id } }
    }

    private func resetHubData() {
        buffer = []
        seenIds = []
        derivedSessions = [:]
        lastLogId = nil
        syntheticId = 0
        consoleLines = []
        sessions = []
        usageSnapshot = nil
        jobs = []
        usageState = .loading
        jobsState = .loading
        sessionsState = .loading
        dispatchState = nil
        catalogue = .empty
        sessionsUpdatedAt = nil
        statusLine = "No hub connected"
    }

    private func startConnection() {
        runTask?.cancel()
        generation += 1
        let gen = generation
        if let old = liveSession {
            Task { await old.close() }
        }
        liveSession = nil
        client = nil
        capabilities = []
        relayOnly = false
        guard let hub = activeHub else {
            connection = .offline(retryIn: nil)
            statusLine = "No hub connected"
            return
        }
        connection = .connecting
        statusLine = "Connecting to \(hub.name)"
        runTask = Task { [weak self] in
            await self?.run(hubId: hub.id, generation: gen)
        }
    }

    private func run(hubId: String, generation gen: Int) async {
        var backoff = Backoff()
        while !Task.isCancelled, gen == generation {
            guard let hub = hubs.first(where: { $0.id == hubId }),
                  let key = try? store.key(for: hubId) else {
                connection = .authFailed
                return
            }
            connection = .connecting
            let endpoint = PairedEndpoint(record: hub, key: key)
            let result = await makeLadder(endpoint, clock, lastLogId).resolve()
            guard gen == generation, !Task.isCancelled else {
                await result.session?.close()
                return
            }
            switch result {
            case .failed(let error):
                if terminal(error, hubId: hubId) { return }
            case .connected(let session, let relayOnly):
                liveSession = session
                // The session's own API route (iroh) wins. A LAN session has
                // none, so the LAN client answers.
                client = session.api.map { HubClient(api: $0) } ?? makeClient(endpoint)
                store.markConnected(id: hubId)
                syncFromStore()
                backoff.reset()
                begin(session, relayOnly: relayOnly)
                let error = await consume(session)
                await session.close()
                guard gen == generation else { return }
                if liveSession === session { liveSession = nil }
                client = nil
                if let error, terminal(error, hubId: hubId) { return }
            }
            let delay = backoff.next()
            capabilities = []
            relayOnly = false
            connection = .offline(retryIn: delay)
            statusLine = UserMessages.offlineHub
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    /// Sets authFailed or keyRevoked and returns true when the error ends the
    /// retry loop.
    private func terminal(_ error: TransportError, hubId: String) -> Bool {
        let everConnected = hubs.first(where: { $0.id == hubId })?.everConnected ?? false
        switch FailureOutcome.classify(error, everConnected: everConnected) {
        case .authFailed:
            capabilities = []
            connection = .authFailed
            return true
        case .keyRevoked:
            capabilities = []
            connection = .keyRevoked
            return true
        case .offline:
            return false
        }
    }

    private func begin(_ session: HubSession, relayOnly viaIrohOnly: Bool) {
        capabilities = session.capabilities
        relayOnly = viaIrohOnly
        let route = session.route
        connection = .online(route, session.capabilities)
        if session.capabilities.contains(.usage) {
            statusLine = "Connected to \(activeHub?.name ?? "the hub")"
            let gen = generation
            Task { [weak self] in await self?.refreshAll(generation: gen) }
        } else {
            statusLine = "Connected through iroh (\(route == .relay ? "relay" : "direct"))"
            if derivedSessions.isEmpty == false { sessions = sortedDerived() }
        }
    }

    /// "<hub name> is healthy". The route pill shows the transport, so the
    /// hub's own transport label (which reads "Loopback only" on a LAN hub)
    /// is left out of this line.
    static func statusText(_ status: MobileStatus, hubName: String) -> String {
        let name = hubName.trimmingCharacters(in: .whitespaces).isEmpty ? "The hub" : hubName
        let state = status.status.trimmingCharacters(in: .whitespaces)
        return name + " is " + (state.isEmpty ? "reachable" : state)
    }

    private func refreshAll(generation gen: Int) async {
        guard let client else { return }
        // The status call comes last: the real hub can take seconds to answer
        // it, and the panels must not wait for it.
        await refreshSessions()
        await refreshUsage()
        await refreshJobs()
        await refreshCatalogue()
        if let status = try? await client.status(), gen == generation {
            statusLine = Self.statusText(status, hubName: activeHub?.name ?? "")
        }
    }

    /// Reads frames until the stream ends or fails. A silent stream ends after
    /// 45 s. Returns the error that ended it, if any.
    private func consume(_ session: HubSession) async -> TransportError? {
        let watchdog = PingWatchdog(clock: clock, onTimeout: {
            Task { await session.close() }
        })
        watchdog.start()
        defer { watchdog.stop() }
        do {
            for try await frame in session.frames {
                watchdog.kick()
                if case .error(let detail) = frame {
                    return ConsoleFrame.mapError(detail: detail)
                }
                handle(frame)
            }
            return watchdog.hasFired ? .timedOut : nil
        } catch {
            return TransportError.normalise(error)
        }
    }

    private func handle(_ frame: ConsoleFrame) {
        switch frame {
        case .hello, .ping:
            if let reported = frame.reportedRoute, case .online(let current, let caps) = connection,
               current != reported {
                connection = .online(reported, caps)
            }
        case .log(let entry):
            ingest(entry)
        case .error:
            break
        }
    }

    // MARK: Console buffer

    func ingest(_ entry: ConsoleFrame.LogEntry) {
        let id: Int
        if let hubId = entry.id {
            id = hubId
        } else {
            syntheticId -= 1
            id = syntheticId
        }
        guard !seenIds.contains(id) else { return }
        seenIds.insert(id)
        if entry.id != nil { lastLogId = max(lastLogId ?? id, id) }
        let line = ConsoleLine(id: id, agent: entry.agent ?? "", source: entry.source ?? "",
                               content: entry.content ?? "", timestamp: entry.timestamp,
                               sessionId: entry.sessionId)
        buffer.append(line)
        if buffer.count > AppModel.ringCapacity {
            let overflow = buffer.count - AppModel.ringCapacity
            for old in buffer.prefix(overflow) { seenIds.remove(old.id) }
            buffer.removeFirst(overflow)
        }
        derive(from: line)
        republishLines()
    }

    private func republishLines() {
        if let agent = agentFilter {
            consoleLines = buffer.filter { $0.agent == agent }
        } else {
            consoleLines = buffer
        }
    }

    private func derive(from line: ConsoleLine) {
        guard let sid = line.sessionId, !sid.isEmpty else { return }
        var info = derivedSessions[sid]
            ?? SessionInfo(id: sid, agent: nil, workingDirectory: nil, busy: false, idleSeconds: nil,
                           lastActivity: nil, lineCount: 0, fromLog: true)
        if !line.agent.isEmpty, line.agent != "user", line.agent != "system" { info.agent = line.agent }
        info.lastActivity = line.timestamp ?? info.lastActivity
        info.lineCount += 1
        derivedSessions[sid] = info
        if sessionsAreDerived { sessions = sortedDerived() }
    }

    private func sortedDerived() -> [SessionInfo] {
        derivedSessions.values.sorted {
            ($0.lastActivity ?? "", $0.id) > ($1.lastActivity ?? "", $1.id)
        }
    }
}

#if DEBUG
// MARK: - Debug support

extension AppModel {
    private static let placeholderPayload = PairingPayload(
        version: 1, name: "Test Hub", lanHost: "192.0.2.10", lanPort: 18845,
        fingerprint: String(repeating: "a", count: 64),
        hubId: Data(repeating: 0x42, count: 16), key: Data(repeating: 0x41, count: 32),
        irohTicket: nil)

    /// Builds the model for UI tests. Returns nil when no debug variable is set.
    /// AGNVIEW_MOCK_HUB_URL pairs the mock hub and connects over LAN.
    /// AGNVIEW_FORCE_STATE puts the model in a fixed state without a hub:
    /// offline, authFailed, keyRevoked, relayOnly or iroh.
    static func debugLaunchModel() -> AppModel? {
        let env = ProcessInfo.processInfo.environment
        let forced = env["AGNVIEW_FORCE_STATE"].flatMap { $0.isEmpty ? nil : $0 }
        let mock = MockHub.baseURL
        guard forced != nil || mock != nil else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agnview-debug-\(UUID().uuidString)", isDirectory: true)
        let model: AppModel
        if mock != nil {
            model = AppModel(
                secrets: InMemorySecretStore(), directory: directory,
                makeLadder: { endpoint, clock, afterId in
                    ConnectionLadder(
                        endpoint: MockEndpoint(base: endpoint), clock: clock,
                        makeLAN: { ep in
                            LANTransport(baseURL: LANTransport.baseURL(host: ep.lanHost, port: ep.lanPort),
                                         token: MockHub.pairingKey)
                        },
                        makeIroh: { ep, ticket in
                            IrohTransport(ticket: ticket, token: ep.token, afterId: afterId)
                        })
                },
                makeClient: { ep in
                    HubClient(baseURL: LANTransport.baseURL(host: ep.lanHost, port: ep.lanPort),
                              token: MockHub.pairingKey)
                })
        } else {
            model = AppModel(secrets: InMemorySecretStore(), directory: directory)
        }
        model.debugForcedState = forced
        model.debugMockURL = mock
        return model
    }

    func pairMockHub(_ url: URL) {
        let payload = PairingPayload(
            version: 1, name: "Mock Hub", lanHost: url.host ?? "127.0.0.1", lanPort: url.port ?? 18081,
            fingerprint: String(repeating: "a", count: 64),
            hubId: Data(repeating: 0x4D, count: 16), key: Data(MockHub.pairingKey.utf8),
            irohTicket: nil)
        _ = try? store.add(payload: payload)
        syncFromStore()
    }

    /// Returns true when the state name is known and applied.
    func applyForcedState(_ name: String) -> Bool {
        let states = ["offline", "authFailed", "keyRevoked", "relayOnly", "iroh"]
        guard states.contains(name) else { return false }
        if hubs.isEmpty {
            _ = try? store.add(payload: AppModel.placeholderPayload)
            syncFromStore()
        }
        runTask?.cancel()
        generation += 1
        pairingResult = .idle
        switch name {
        case "offline":
            connection = .offline(retryIn: nil)
            statusLine = UserMessages.offlineHub
        case "authFailed":
            connection = .authFailed
        case "keyRevoked":
            connection = .keyRevoked
        default:
            resetHubData()
            connection = .online(.direct, .iroh)
            capabilities = .iroh
            relayOnly = name == "relayOnly"
            statusLine = "Connected through iroh (direct)"
            let samples: [(String, String, String, String?)] = [
                ("system", "system_notice", "Placeholder hub started", nil),
                ("claude_code", "stdout", "Example output line", "session-1"),
                ("user", "user_input", "Example prompt", "session-1"),
                ("codex", "stdout", "Another example line", "session-2"),
            ]
            for (index, sample) in samples.enumerated() {
                ingest(ConsoleFrame.LogEntry(id: index + 1, agent: sample.0, source: sample.1,
                                             content: sample.2, timestamp: "2026-01-01T00:00:0\(index)Z",
                                             sessionId: sample.3))
            }
            if name == "iroh" {
                let account = UsageAccount(id: "acc-claude", name: "Example Claude", provider: "claude",
                                           planName: "Example plan", tokensUsed: 120000, tokensLimit: 500000,
                                           costUsed: 12.5, costLimit: 100.0, requestsCount: 42,
                                           lastProbed: nil, isActive: true)
                let snapshot = UsageSnapshot(accounts: [account], takenAt: now().addingTimeInterval(-300))
                usageSnapshot = snapshot
                usageState = .stale(snapshot, since: snapshot.takenAt)
            }
        }
        return true
    }
}

/// Mock hub endpoint: the mock listens on loopback, so LAN must not be skipped.
struct MockEndpoint: HubEndpoint {
    let base: HubEndpoint
    var lanHost: String { base.lanHost }
    var lanPort: Int { base.lanPort }
    var key: Data { base.key }
    var irohTicket: String? { base.irohTicket }
    var isLoopbackLAN: Bool { false }
}
#endif
