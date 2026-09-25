import Foundation

/// Time source for the ladder, the watchdog and backoff. Tests use FakeClock.
protocol Clock: AnyObject {
    func sleep(for duration: Duration) async throws
    var now: ContinuousClock.Instant { get }
}

final class SystemClock: Clock {
    private let clock = ContinuousClock()

    init() {}

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
    }

    var now: ContinuousClock.Instant { clock.now }
}

/// Manual clock for tests. Time moves only through `advance(by:)`.
final class FakeClock: Clock {
    private struct Sleeper {
        let id: Int
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum Decision { case cancelled, due, waiting }

    private let lock = NSLock()
    private var current: ContinuousClock.Instant
    private var sleepers: [Sleeper] = []
    private var nextId = 0

    init(start: ContinuousClock.Instant = ContinuousClock().now) {
        current = start
    }

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    /// Number of tasks waiting in `sleep(for:)`.
    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        let (id, deadline) = lock.withLock { () -> (Int, ContinuousClock.Instant) in
            let id = nextId
            nextId += 1
            return (id, current.advanced(by: duration))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let decision = lock.withLock { () -> Decision in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= current { return .due }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .waiting
                }
                switch decision {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let removed = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline passed.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let now = current
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due.sorted(by: { $0.deadline < $1.deadline }) {
            sleeper.continuation.resume()
        }
    }

    /// Waits in real time, up to `limit`, until at least `count` tasks sleep.
    @discardableResult
    func waitForSleepers(_ count: Int = 1, limit: Duration = .seconds(5)) async -> Bool {
        let wall = ContinuousClock()
        let end = wall.now.advanced(by: limit)
        while sleeperCount < count {
            if wall.now >= end { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
}
