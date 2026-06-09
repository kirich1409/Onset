import Foundation

// MARK: - DiagnosticLogEntry

/// A single, immutable log entry collected from the app's OS log store.
///
/// Pure value type: no dependencies, no I/O. Carries all display-relevant fields
/// extracted from `OSLogEntryLog` so the rest of the system never imports OSLog directly.
struct DiagnosticLogEntry: Equatable {
    // MARK: - Level

    /// Mirrors `OSLogEntryLog.Level` without importing OSLog outside the data layer.
    enum Level: String, Equatable {
        /// `OSLogEntryLog.Level.undefined`
        case undefined
        /// `OSLogEntryLog.Level.debug`
        case debug
        /// `OSLogEntryLog.Level.info`
        case info
        /// `OSLogEntryLog.Level.notice`
        case notice
        /// `OSLogEntryLog.Level.error`
        case error
        /// `OSLogEntryLog.Level.fault`
        case fault
    }

    // MARK: - Properties

    /// Timestamp from `OSLogEntry.date`.
    let date: Date
    /// Subsystem from `OSLogEntry.subsystem` (always `dev.androidbroadcast.Onset` in practice).
    let subsystem: String
    /// Category from `OSLogEntry.category`.
    let category: String
    /// Severity level.
    let level: Level
    /// Human-readable message from `OSLogEntryLog.composedMessage`.
    let message: String
}
