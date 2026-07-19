@testable import Onset

// MARK: - Fake

/// Scriptable `MonotonicClock` for deterministic `readEvery`-throttle tests — no wall-clock
/// sleep. `@MainActor` (implicit, matching `MonotonicClock`'s isolation): tests advance it
/// directly, and `DiskSpaceMonitor` reads it from the same actor.
@MainActor
final class FakeMonotonicClock: MonotonicClock {
    /// The current simulated time, in seconds.
    private(set) var current: Double = 0

    func now() -> Double {
        self.current
    }

    /// Advances simulated time by `seconds`, as a tick loop's clock would.
    func advance(by seconds: Double) {
        self.current += seconds
    }
}
