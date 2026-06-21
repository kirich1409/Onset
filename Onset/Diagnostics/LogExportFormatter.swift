import Foundation

// MARK: - LogExportFormatter

/// Formats a list of `DiagnosticLogEntry` values into a plain-text diagnostic report
/// and generates a time-stamped filename for the exported file.
///
/// Pure, nonisolated — no actor context required, safe to call from any isolation domain.
enum LogExportFormatter {
    // MARK: - Constants

    nonisolated private static let subsystem = "dev.androidbroadcast.Onset"

    // MARK: - Filename

    /// Generates a stable, sortable filename for the diagnostic export.
    ///
    /// Format: `onset-diagnostics-YYYY-MM-DD-HHmmss.log`
    ///
    /// - Parameter date: The timestamp to embed; defaults to the current date.
    /// - Returns: A filesystem-safe filename string.
    nonisolated static func filename(for date: Date = Date()) -> String {
        let formatted = Self.filenameFormatter.string(from: date)
        return "onset-diagnostics-\(formatted).log"
    }

    // MARK: - Formatting

    /// Formats a list of log entries into a UTF-8 text block.
    ///
    /// The output starts with a one-line header, then one line per entry in ISO 8601 order.
    /// Entries are assumed to be pre-sorted ascending by date.
    ///
    /// - Parameters:
    ///   - entries: The entries to format. May be empty — the header is always emitted.
    ///   - generatedAt: The export timestamp inserted into the header.
    /// - Returns: The complete text content, terminated with a newline.
    nonisolated static func format(entries: [DiagnosticLogEntry], generatedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append(Self.header(generatedAt: generatedAt, entryCount: entries.count))
        lines.append("")
        for entry in entries {
            lines.append(Self.line(for: entry))
        }
        lines.append("") // trailing newline when joined
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    nonisolated private static func header(generatedAt: Date, entryCount: Int) -> String {
        let timestamp = Self.iso8601Formatter.string(from: generatedAt)
        return "# \(self.subsystem) diagnostics — \(timestamp) — \(entryCount) entries"
    }

    nonisolated private static func line(for entry: DiagnosticLogEntry) -> String {
        let timestamp = Self.lineFormatter.string(from: entry.date)
        let levelTag = entry.level.rawValue.uppercased()
        // Format: "2024-01-15 12:34:56.789 [ERROR] CategoryName: message text"
        return "\(timestamp) [\(levelTag)] \(entry.category): \(entry.message)"
    }

    // MARK: - Formatters (reused across calls — DateFormatter is expensive to allocate)

    // nonisolated: DateFormatter is class-based but written once at init time (thread-safe
    // reads after initialization). All formatter instances are lazily initialized before
    // any concurrent access begins (enum static stored properties are initialized on first
    // access under a lock by the Swift runtime).
    nonisolated private static let filenameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    nonisolated private static let iso8601Formatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    nonisolated private static let lineFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt
    }()
}
