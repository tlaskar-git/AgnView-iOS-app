import Foundation

/// Fires once when no frame arrives for `timeout`. The hub pings every 15 s
/// on an idle stream, so the default of 45 s is three missed pings.
final class PingWatchdog {
    static let defaultTimeout: Duration = .seconds(45)

    let timeout: Duration
    private let clock: Clock
    private let onTimeout: @Sendable () -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var fired = false

    init(clock: Clock, timeout: Duration = PingWatchdog.defaultTimeout,
         onTimeout: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    deinit {
        task?.cancel()
    }

    var hasFired: Bool {
        lock.withLock { fired }
    }

    /// Starts or restarts the countdown.
    func start() {
        lock.withLock { fired = false }
        kick()
    }

    /// Call on every frame. Restarts the countdown.
    func kick() {
        let clock = self.clock
        let timeout = self.timeout
        let (previous, current) = lock.withLock { () -> (Task<Void, Never>?, Int) in
            generation += 1
            return (task, generation)
        }
        previous?.cancel()
        let next = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            self?.expire(generation: current)
        }
        lock.withLock {
            if generation == current { task = next } else { next.cancel() }
        }
    }

    func stop() {
        let previous = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            let running = task
            task = nil
            return running
        }
        previous?.cancel()
    }

    private func expire(generation expected: Int) {
        let shouldFire = lock.withLock { () -> Bool in
            guard generation == expected, !fired else { return false }
            fired = true
            return true
        }
        if shouldFire { onTimeout() }
    }
}
