@testable import Onset

// MARK: - Fake

/// In-memory fake `DisplaySleepPreventing` for unit tests.
///
/// All state is per-instance — safe under Swift Testing's parallel-by-default execution
/// (each `@Test` in a `@Suite struct` receives a fresh instance).
@MainActor
final class FakeDisplaySleepPreventer: DisplaySleepPreventing {
    // MARK: - Call tracking

    /// Number of times `beginPreventingSleep()` was called.
    private(set) var beginCallCount = 0

    /// Number of times `endPreventingSleep()` was called.
    private(set) var endCallCount = 0

    /// `true` between a `beginPreventingSleep()` call and the matching `endPreventingSleep()` —
    /// mirrors the live implementation's idempotent begin/end pairing.
    private(set) var isPreventingSleep = false

    // MARK: - DisplaySleepPreventing

    /// Records the call synchronously; mirrors the live implementation's idempotency (a second
    /// `beginPreventingSleep()` while already active still increments the counter for assertions,
    /// but tests care about `isPreventingSleep`, not the raw count, to verify no leaked hold).
    func beginPreventingSleep() {
        self.beginCallCount += 1
        self.isPreventingSleep = true
    }

    /// Records the call synchronously.
    func endPreventingSleep() {
        self.endCallCount += 1
        self.isPreventingSleep = false
    }
}
