import Foundation

/// Reconnect delays: 1, 2, 4, 8, then 15 s for every later attempt.
struct Backoff {
    static let schedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    private(set) var attempt = 0

    init() {}

    mutating func next() -> Duration {
        let index = min(attempt, Backoff.schedule.count - 1)
        attempt += 1
        return Backoff.schedule[index]
    }

    mutating func reset() {
        attempt = 0
    }

    /// Sleeps for the next delay on the given clock.
    mutating func wait(on clock: Clock) async throws {
        try await clock.sleep(for: next())
    }
}
