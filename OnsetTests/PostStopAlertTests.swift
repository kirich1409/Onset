// PostStopAlertTests.swift
// OnsetTests
//
// Swift Testing suite for PostStopAlert.resolve(writeError:droppedFrames:).
//
// Tests all combinations of the two input dimensions to verify the priority rule:
// writeError wins over degradedWarning when both are set simultaneously.
// Also verifies that droppedFrames is forwarded into the .degradedWarning associated value,
// and that the .message computed property produces the correct AC-9 phrase forms.
//
@testable import Onset
import Testing

// MARK: - PostStopAlert.resolve Tests

@Suite("PostStopAlert.resolve — priority ordering")
struct PostStopAlertResolveTests {
    @Test("neither flag set → nil")
    func neitherFlag_returnsNil() {
        let alert = PostStopAlert.resolve(writeError: nil, droppedFrames: 0)
        #expect(alert == nil)
    }

    @Test("writeError only → .writeError with the reason string")
    func writeErrorOnly_returnsWriteError() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", droppedFrames: 0)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }

    @Test("droppedFrames > 0, no writeError → .degradedWarning with droppedFrames forwarded")
    func degradedWarningOnly_returnsDegradedWarning() {
        let alert = PostStopAlert.resolve(writeError: nil, droppedFrames: 42)
        guard case let .degradedWarning(droppedFrames) = alert else {
            Issue.record("Expected .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(droppedFrames == 42)
    }

    @Test("both writeError and droppedFrames > 0 → .writeError wins (higher severity)")
    func bothSet_writeErrorWins() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", droppedFrames: 7)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError to supersede .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }

    @Test("droppedFrames == 0 after acknowledge → nil (no stale alert)")
    func zeroDroppedFrames_returnsNil() {
        // Simulates the coordinator state after acknowledgeDegradedWarning() resets lastDroppedFrames = 0.
        let alert = PostStopAlert.resolve(writeError: nil, droppedFrames: 0)
        #expect(alert == nil)
    }
}

// MARK: - PostStopAlert.message Tests (AC-9 phrase)

@Suite("PostStopAlert.degradedWarning.message — AC-9 alert phrase")
struct PostStopAlertMessageTests {
    @Test("1 → Пропущен 1 кадр — возможны рывки.")
    func count1_singleFramePhrase() {
        #expect(PostStopAlert.degradedWarning(droppedFrames: 1).message == "Пропущен 1 кадр — возможны рывки.")
    }

    @Test("2 → Пропущено 2 кадра — возможны рывки.")
    func count2_fewFramesPhrase() {
        #expect(PostStopAlert.degradedWarning(droppedFrames: 2).message == "Пропущено 2 кадра — возможны рывки.")
    }

    @Test("5 → Пропущено 5 кадров — возможны рывки.")
    func count5_manyFramesPhrase() {
        #expect(PostStopAlert.degradedWarning(droppedFrames: 5).message == "Пропущено 5 кадров — возможны рывки.")
    }

    @Test("21 → Пропущен 21 кадр — возможны рывки. (one form)")
    func count21_oneFormPhrase() {
        #expect(PostStopAlert.degradedWarning(droppedFrames: 21).message == "Пропущен 21 кадр — возможны рывки.")
    }
}
