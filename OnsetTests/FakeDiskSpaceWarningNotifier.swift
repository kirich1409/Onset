@testable import Onset

// MARK: - Fake

/// In-memory fake `DiskSpaceWarningNotifying` for unit tests.
///
/// All state is per-instance — safe under Swift Testing's parallel-by-default execution
/// (each `@Test` in a `@Suite struct` receives a fresh instance).
@MainActor
final class FakeDiskSpaceWarningNotifier: DiskSpaceWarningNotifying {
    // MARK: - Call tracking

    /// Reasons passed to `notifyLowSpaceWarning(reason:)`, in call order.
    private(set) var warningReasons: [DiskWarningReason] = []

    /// `(reason, filesSaved)` pairs passed to `notifyAutoStopped(reason:filesSaved:)`, in call order.
    private(set) var autoStoppedCalls: [(reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles)] = []

    // MARK: - DiskSpaceWarningNotifying

    /// Records the call synchronously; does not post any real notification.
    func notifyLowSpaceWarning(reason: DiskWarningReason) {
        self.warningReasons.append(reason)
    }

    /// Records the call synchronously; does not post any real notification.
    func notifyAutoStopped(reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles) {
        self.autoStoppedCalls.append((reason: reason, filesSaved: filesSaved))
    }
}
