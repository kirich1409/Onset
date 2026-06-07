// PostStopAlertTests.swift
// OnsetTests
//
// Swift Testing suite for PostStopAlert.resolve(writeError:degraded:droppedFrames:).
//
// Tests all four combinations of the two input flags to verify the priority rule:
// writeError wins over degradedWarning when both are set simultaneously.
// Also verifies that droppedFrames is forwarded into the .degradedWarning associated value.
//
@testable import Onset
import Testing

// MARK: - PostStopAlert.resolve Tests

@Suite("PostStopAlert.resolve — priority ordering")
struct PostStopAlertResolveTests {
    @Test("neither flag set → nil")
    func neitherFlag_returnsNil() {
        let alert = PostStopAlert.resolve(writeError: nil, degraded: false, droppedFrames: 0)
        #expect(alert == nil)
    }

    @Test("writeError only → .writeError with the reason string")
    func writeErrorOnly_returnsWriteError() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", degraded: false, droppedFrames: 0)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }

    @Test("degradedWarning only → .degradedWarning with droppedFrames forwarded")
    func degradedWarningOnly_returnsDegradedWarning() {
        let alert = PostStopAlert.resolve(writeError: nil, degraded: true, droppedFrames: 42)
        guard case let .degradedWarning(droppedFrames) = alert else {
            Issue.record("Expected .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(droppedFrames == 42)
    }

    @Test("both flags set → .writeError wins (higher severity)")
    func bothSet_writeErrorWins() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", degraded: true, droppedFrames: 7)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError to supersede .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }
}
