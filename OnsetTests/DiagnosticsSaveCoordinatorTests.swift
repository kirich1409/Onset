import Foundation
@testable import Onset
import Testing

// MARK: - DiagnosticsSaveCoordinatorTests

@Suite("DiagnosticsSaveCoordinator")
@MainActor
struct DiagnosticsSaveCoordinatorTests {
    // MARK: - Helpers

    private static let referenceDate: Date = {
        // 2024-03-15 10:30:00 UTC — fixed anchor shared with LogExportFormatterTests.
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 3
        comps.day = 15
        comps.hour = 10
        comps.minute = 30
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        // Force-unwrap: all components are valid literals; a nil result is a programming error.
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    private func makeEntry(
        date: Date = referenceDate,
        category: String = "TestCategory",
        level: DiagnosticLogEntry.Level = .info,
        message: String = "hello"
    )
    -> DiagnosticLogEntry {
        DiagnosticLogEntry(
            date: date,
            subsystem: "dev.androidbroadcast.Onset",
            category: category,
            level: level,
            message: message
        )
    }

    // MARK: - makeReport — content

    @Test("makeReport returns formatted content containing entry message")
    func makeReport_containsEntryMessage() async throws {
        let fake = FakeLogEntrySource()
        fake.stubbedEntries = [self.makeEntry(message: "unique-marker-42")]
        let coordinator = DiagnosticsSaveCoordinator(
            logProvider: fake,
            lookBackInterval: 1800
        )

        let report = try await coordinator.makeReport(now: Self.referenceDate)

        #expect(report.contains("unique-marker-42"))
    }

    @Test("makeReport passes correct since date to log provider")
    func makeReport_sinceDate_isNowMinusLookBack() async throws {
        let fake = FakeLogEntrySource()
        let lookBack: TimeInterval = 600
        let coordinator = DiagnosticsSaveCoordinator(
            logProvider: fake,
            lookBackInterval: lookBack
        )

        _ = try await coordinator.makeReport(now: Self.referenceDate)

        let expectedSince = Self.referenceDate.addingTimeInterval(-lookBack)
        #expect(fake.lastSinceDate == expectedSince)
    }

    @Test("makeReport propagates log provider error")
    func makeReport_propagatesError() async throws {
        enum FakeError: Error { case boom }
        let fake = FakeLogEntrySource()
        fake.stubbedError = FakeError.boom
        let coordinator = DiagnosticsSaveCoordinator(logProvider: fake)

        await #expect(throws: FakeError.boom) {
            _ = try await coordinator.makeReport()
        }
    }

    @Test("makeReport produces header containing subsystem")
    func makeReport_header_containsSubsystem() async throws {
        let fake = FakeLogEntrySource()
        let coordinator = DiagnosticsSaveCoordinator(logProvider: fake)

        let report = try await coordinator.makeReport(now: Self.referenceDate)

        #expect(report.contains("dev.androidbroadcast.Onset"))
    }

    // MARK: - makeReport — provider call tracking

    @Test("makeReport calls log provider exactly once")
    func makeReport_callsProviderOnce() async throws {
        let fake = FakeLogEntrySource()
        let coordinator = DiagnosticsSaveCoordinator(logProvider: fake)

        _ = try await coordinator.makeReport()

        #expect(fake.callCount == 1)
    }
}
