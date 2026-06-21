import Foundation
import OSLog

// MARK: - Logger

nonisolated private let diagnosticsLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DiagnosticsExportService"
)

// MARK: - DiagnosticsExportService

/// Live implementation of `LogEntryProviding` that reads from the app's OS log store.
///
/// Uses `OSLogStore(scope: .currentProcessIdentifier)` — reads only entries produced by
/// this process; no special entitlement is required (macOS 12.0+).
///
/// Implemented as a non-isolated struct because `OSLogStore` APIs perform synchronous I/O
/// that should not block the main actor; the `async throws` on `entries(since:)` lets callers
/// schedule this work via a detached or cooperative-pool task.
///
/// > Note: `OSLogStore` is *purely local*: it never opens a network socket, so it satisfies
/// > the no-network invariant enforced by `check-no-network.sh`.
struct OSLogEntryProvider: LogEntryProviding {
    // MARK: - Constants

    // nonisolated: referenced from collectEntries which is nonisolated.
    nonisolated private static let appSubsystem = "dev.androidbroadcast.Onset"

    // MARK: - LogEntryProviding

    func entries(since: Date) async throws -> [DiagnosticLogEntry] {
        // OSLogStore.getEntries performs blocking disk I/O — hop off the caller's actor.
        try await Task.detached(priority: .userInitiated) {
            try Self.collectEntries(since: since)
        }.value
    }

    // MARK: - Private

    // nonisolated: called from a detached task (not on MainActor); safe because all
    // inputs are Sendable value types and the result is a pure Sendable array.
    nonisolated private static func collectEntries(since: Date) throws -> [DiagnosticLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", Self.appSubsystem)

        let rawEntries = try store.getEntries(at: position, matching: predicate)
        var result: [DiagnosticLogEntry] = []

        for entry in rawEntries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            result.append(DiagnosticLogEntry(
                date: logEntry.date,
                subsystem: logEntry.subsystem,
                category: logEntry.category,
                level: DiagnosticLogEntry.Level(logEntry.level),
                message: logEntry.composedMessage
            ))
        }

        diagnosticsLogger.info("Collected \(result.count) log entries since \(since)")
        return result
    }
}

// MARK: - OSLogEntryLog.Level → DiagnosticLogEntry.Level mapping

extension DiagnosticLogEntry.Level {
    // nonisolated: used inside the nonisolated collectEntries helper.
    nonisolated fileprivate init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .undefined: self = .undefined
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .fault
        @unknown default: self = .undefined
        }
    }
}
