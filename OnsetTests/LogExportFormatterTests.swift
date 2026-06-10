import Foundation
@testable import Onset
import Testing

// MARK: - LogExportFormatterTests

@Suite("LogExportFormatter")
struct LogExportFormatterTests {
    // MARK: - Helpers

    private static let referenceDate: Date = {
        // 2024-03-15 10:30:00 UTC — a fixed anchor used across formatter tests.
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 3
        comps.day = 15
        comps.hour = 10
        comps.minute = 30
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        // Force-unwrap: all components are valid literals; a nil result here is a programming error.
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    private func makeEntry(
        date: Date = referenceDate,
        subsystem: String = "dev.androidbroadcast.Onset",
        category: String = "TestCategory",
        level: DiagnosticLogEntry.Level = .info,
        message: String = "Test message"
    )
    -> DiagnosticLogEntry {
        DiagnosticLogEntry(
            date: date,
            subsystem: subsystem,
            category: category,
            level: level,
            message: message
        )
    }

    // MARK: - filename tests

    @Test("filename_containsDateComponents")
    func filename_containsDateComponents() {
        let name = LogExportFormatter.filename(for: Self.referenceDate)
        // Must contain the date portion and the base prefix.
        #expect(name.hasPrefix("onset-diagnostics-"))
        #expect(name.hasSuffix(".log"))
        #expect(name.contains("2024-03-15"))
    }

    @Test("filename_containsTimeComponents")
    func filename_containsTimeComponents() {
        let name = LogExportFormatter.filename(for: Self.referenceDate)
        // Time in UTC: 10:30:00 → "103000"
        #expect(name.contains("103000"))
    }

    @Test("filename_isDeterministic")
    func filename_isDeterministic() {
        let first = LogExportFormatter.filename(for: Self.referenceDate)
        let second = LogExportFormatter.filename(for: Self.referenceDate)
        #expect(first == second)
    }

    // MARK: - format tests

    @Test("format_emptyEntries_containsHeader")
    func format_emptyEntries_containsHeader() {
        let output = LogExportFormatter.format(entries: [], generatedAt: Self.referenceDate)
        #expect(output.contains("dev.androidbroadcast.Onset diagnostics"))
        #expect(output.contains("0 entries"))
    }

    @Test("format_singleEntry_containsMessageAndLevel")
    func format_singleEntry_containsMessageAndLevel() {
        let entry = self.makeEntry(level: .error, message: "Something went wrong")
        let output = LogExportFormatter.format(entries: [entry], generatedAt: Self.referenceDate)

        #expect(output.contains("[ERROR]"))
        #expect(output.contains("Something went wrong"))
        #expect(output.contains("TestCategory"))
    }

    @Test("format_multipleEntries_allPresent")
    func format_multipleEntries_allPresent() {
        let entries = [
            makeEntry(message: "first"),
            makeEntry(message: "second"),
            makeEntry(message: "third"),
        ]
        let output = LogExportFormatter.format(entries: entries, generatedAt: Self.referenceDate)

        #expect(output.contains("first"))
        #expect(output.contains("second"))
        #expect(output.contains("third"))
        #expect(output.contains("3 entries"))
    }

    @Test("format_faultLevel_upperCased")
    func format_faultLevel_upperCased() {
        let entry = self.makeEntry(level: .fault, message: "critical")
        let output = LogExportFormatter.format(entries: [entry], generatedAt: Self.referenceDate)
        #expect(output.contains("[FAULT]"))
    }

    @Test("format_debugLevel_upperCased")
    func format_debugLevel_upperCased() {
        let entry = self.makeEntry(level: .debug, message: "verbose")
        let output = LogExportFormatter.format(entries: [entry], generatedAt: Self.referenceDate)
        #expect(output.contains("[DEBUG]"))
    }

    @Test("format_endsWithNewline")
    func format_endsWithNewline() {
        let output = LogExportFormatter.format(entries: [], generatedAt: Self.referenceDate)
        #expect(output.hasSuffix("\n"))
    }

    @Test("format_noticeLevel_upperCased")
    func format_noticeLevel_upperCased() {
        let entry = self.makeEntry(level: .notice, message: "notice")
        let output = LogExportFormatter.format(entries: [entry], generatedAt: Self.referenceDate)
        #expect(output.contains("[NOTICE]"))
    }

    // MARK: - DiagnosticLogEntry.Level raw values

    @Test("level_rawValues_matchExpected")
    func level_rawValues_matchExpected() {
        #expect(DiagnosticLogEntry.Level.undefined.rawValue == "undefined")
        #expect(DiagnosticLogEntry.Level.debug.rawValue == "debug")
        #expect(DiagnosticLogEntry.Level.info.rawValue == "info")
        #expect(DiagnosticLogEntry.Level.notice.rawValue == "notice")
        #expect(DiagnosticLogEntry.Level.error.rawValue == "error")
        #expect(DiagnosticLogEntry.Level.fault.rawValue == "fault")
    }
}
