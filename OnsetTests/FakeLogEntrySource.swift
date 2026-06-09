import Foundation
@testable import Onset

// MARK: - FakeLogEntrySource

/// A fully in-memory fake implementation of `LogEntryProviding` for use in unit tests.
///
/// All state is per-instance so Swift Testing's parallel-by-default execution is safe:
/// each `@Test` in a `@Suite struct` receives a fresh instance.
///
/// Configure `stubbedEntries` before the system under test calls `entries(since:)` to
/// control the returned values. Set `stubbedError` to simulate store-open / query failures.
final class FakeLogEntrySource: LogEntryProviding, @unchecked Sendable {
    // MARK: - Configuration

    /// Entries returned from `entries(since:)`. Defaults to empty.
    var stubbedEntries: [DiagnosticLogEntry] = []

    /// When non-nil, thrown from `entries(since:)` instead of returning `stubbedEntries`.
    var stubbedError: Error?

    // MARK: - Call tracking

    private(set) var callCount = 0
    private(set) var lastSinceDate: Date?

    // MARK: - LogEntryProviding

    func entries(since: Date) async throws -> [DiagnosticLogEntry] {
        self.callCount += 1
        self.lastSinceDate = since
        if let error = self.stubbedError {
            throw error
        }
        return self.stubbedEntries
    }
}
