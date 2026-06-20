@testable import Onset

// MARK: - Fake

/// In-memory fake `RecordingStartNotifying` for unit tests.
///
/// All state is per-instance — safe under Swift Testing's parallel-by-default execution
/// (each `@Test` in a `@Suite struct` receives a fresh instance).
@MainActor
final class FakeRecordingStartNotifier: RecordingStartNotifying {
    // MARK: - Call tracking

    /// Number of times `notifyRecordingStarted()` was called.
    private(set) var notifyCallCount = 0

    // MARK: - RecordingStartNotifying

    /// Records the call synchronously; does not post any real notification.
    func notifyRecordingStarted() {
        self.notifyCallCount += 1
    }
}
