import Foundation

/// Reads the next chunk of a byte stream. Nil or empty data means the stream
/// ended.
typealias ChunkReader = @Sendable () async throws -> Data?

extension TransportError {
    /// Keeps a transport error as it is and maps anything else to unreachable.
    static func normalise(_ error: Error) -> TransportError {
        if let known = error as? TransportError { return known }
        if error is CancellationError { return .unreachable }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timedOut : .unreachable
        }
        return .unreachable
    }
}

/// A console session over an NDJSON byte stream, as the hub serves it over
/// iroh. The session opens once the hello frame arrives. The route comes from
/// hello.transport and every ping frame updates it.
final class ConsoleStreamSession: HubSession {
    let capabilities: Set<Capability>
    let hello: ConsoleFrame.Hello
    let frames: AsyncThrowingStream<ConsoleFrame, Error>

    private let lock = NSLock()
    private var currentRoute: TransportRoute
    private var pumpTask: Task<Void, Never>?
    private var closed = false
    private let continuation: AsyncThrowingStream<ConsoleFrame, Error>.Continuation
    private let onClose: @Sendable () async -> Void

    var route: TransportRoute {
        lock.withLock { currentRoute }
    }

    /// Reads until the hello frame. An error frame before hello throws the
    /// mapped error: the hub's auth failure detail gives `.unauthorised`.
    static func open(capabilities: Set<Capability> = .iroh,
                     fallbackRoute: TransportRoute = .relay,
                     read: @escaping ChunkReader,
                     onClose: @escaping @Sendable () async -> Void) async throws -> ConsoleStreamSession {
        var framer = NDJSONFramer()
        var hello: ConsoleFrame.Hello?
        var pending: [ConsoleFrame] = []
        do {
            while hello == nil {
                guard let chunk = try await read(), !chunk.isEmpty else {
                    throw TransportError.protocolViolation
                }
                for line in try framer.feed(chunk) {
                    guard let frame = ConsoleFrame.decode(line: line) else { continue }
                    if hello != nil {
                        pending.append(frame)
                        continue
                    }
                    switch frame {
                    case .hello(let value):
                        hello = value
                    case .error(let detail):
                        throw ConsoleFrame.mapError(detail: detail)
                    default:
                        continue
                    }
                }
            }
        } catch {
            await onClose()
            throw TransportError.normalise(error)
        }
        let opened = hello ?? ConsoleFrame.Hello()
        let route = TransportRoute(hubValue: opened.transport) ?? fallbackRoute
        let session = ConsoleStreamSession(capabilities: capabilities, hello: opened,
                                           route: route, onClose: onClose)
        session.start(pending: pending, framer: framer, read: read)
        return session
    }

    private init(capabilities: Set<Capability>, hello: ConsoleFrame.Hello,
                 route: TransportRoute, onClose: @escaping @Sendable () async -> Void) {
        self.capabilities = capabilities
        self.hello = hello
        self.currentRoute = route
        self.onClose = onClose
        var captured: AsyncThrowingStream<ConsoleFrame, Error>.Continuation!
        self.frames = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(10_000)) { captured = $0 }
        self.continuation = captured
    }

    private func start(pending: [ConsoleFrame], framer: NDJSONFramer, read: @escaping ChunkReader) {
        let continuation = self.continuation
        let hello = self.hello
        let task = Task { [weak self] in
            var framer = framer
            continuation.yield(.hello(hello))
            for frame in pending {
                if self?.handle(frame) == false { return }
            }
            while !Task.isCancelled {
                do {
                    guard let chunk = try await read(), !chunk.isEmpty else {
                        if let last = framer.finish(), let frame = ConsoleFrame.decode(line: last) {
                            _ = self?.handle(frame)
                        }
                        continuation.finish()
                        return
                    }
                    for line in try framer.feed(chunk) {
                        guard let frame = ConsoleFrame.decode(line: line) else { continue }
                        if self?.handle(frame) == false { return }
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: TransportError.normalise(error))
                    }
                    return
                }
            }
            continuation.finish()
        }
        lock.withLock { pumpTask = task }
        continuation.onTermination = { _ in task.cancel() }
    }

    /// Returns false when the stream must stop.
    private func handle(_ frame: ConsoleFrame) -> Bool {
        switch frame {
        case .error(let detail):
            continuation.finish(throwing: ConsoleFrame.mapError(detail: detail))
            return false
        case .ping:
            if let reported = frame.reportedRoute {
                lock.withLock { currentRoute = reported }
            }
            continuation.yield(frame)
            return true
        case .hello, .log:
            continuation.yield(frame)
            return true
        }
    }

    func close() async {
        let (already, task) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            let already = closed
            closed = true
            return (already, pumpTask)
        }
        if already { return }
        task?.cancel()
        continuation.finish()
        await onClose()
    }
}
