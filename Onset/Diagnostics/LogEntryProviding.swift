import Foundation

// MARK: - LogEntryProviding

/// DI seam for log-entry collection.
///
/// The live implementation wraps `OSLogStore(scope: .currentProcessIdentifier)`.
/// Test doubles return a fixed array without touching the OS log store.
///
/// Throwing: OSLogStore APIs are documented to throw; implementations propagate the error
/// so callers can surface it to the user rather than silently producing empty exports.
protocol LogEntryProviding: Sendable {
    /// Collects log entries produced by this process since `since`.
    ///
    /// - Parameter since: Lower bound timestamp. Only entries at or after this date are returned.
    /// - Returns: Entries sorted ascending by date, filtered to the app's subsystem.
    /// - Throws: Propagates `OSLogStore` errors if the store cannot be opened or queried.
    func entries(since: Date) async throws -> [DiagnosticLogEntry]
}
