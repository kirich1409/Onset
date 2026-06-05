// PostStopAlertTests.swift
// OnsetTests
//
// Swift Testing suite for PostStopAlert.resolve(writeError:degraded:).
//
// Tests all four combinations of the two input flags to verify the priority rule:
// writeError wins over degradedWarning when both are set simultaneously.
//
@testable import Onset
import Testing

// MARK: - PostStopAlert.resolve Tests

@Suite("PostStopAlert.resolve — priority ordering")
struct PostStopAlertResolveTests {
    @Test("neither flag set → nil")
    func neitherFlag_returnsNil() {
        let alert = PostStopAlert.resolve(writeError: nil, degraded: false)
        #expect(alert == nil)
    }

    @Test("writeError only → .writeError with the reason string")
    func writeErrorOnly_returnsWriteError() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", degraded: false)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }

    @Test("degradedWarning only → .degradedWarning")
    func degradedWarningOnly_returnsDegradedWarning() {
        let alert = PostStopAlert.resolve(writeError: nil, degraded: true)
        guard case .degradedWarning = alert else {
            Issue.record("Expected .degradedWarning, got \(String(describing: alert))")
            return
        }
    }

    @Test("both flags set → .writeError wins (higher severity)")
    func bothSet_writeErrorWins() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", degraded: true)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError to supersede .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }
}
