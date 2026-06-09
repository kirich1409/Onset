// PostStopAlertTests.swift
// OnsetTests
//
// Swift Testing suite for PostStopAlert.resolve(writeError:degraded:droppedFrames:).
//
// Tests all combinations of the input dimensions to verify the priority rule:
// writeError wins over degradedWarning when both are set simultaneously.
// Also verifies that droppedFrames is forwarded into the .degradedWarning associated value
// for message pluralization, and that the .message computed property produces the correct
// AC-9 phrase forms.
//
// The alert gate is `degraded: Bool` (not `droppedFrames > 0`) — the key invariant is that
// a session with non-zero backpressureDrops but degraded == false produces NO alert.
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

    @Test("degraded == true, no writeError → .degradedWarning with droppedFrames forwarded")
    func degradedWarningOnly_returnsDegradedWarning() {
        let alert = PostStopAlert.resolve(writeError: nil, degraded: true, droppedFrames: 42)
        guard case let .degradedWarning(droppedFrames) = alert else {
            Issue.record("Expected .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(droppedFrames == 42)
    }

    @Test("both writeError and degraded == true → .writeError wins (higher severity)")
    func bothSet_writeErrorWins() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.", degraded: true, droppedFrames: 7)
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError to supersede .degradedWarning, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }

    @Test("degraded == false → nil even when droppedFrames > 0 (key regression guard)")
    func degradedFalse_nilEvenWithDroppedFrames() {
        // Regression: old gate was `droppedFrames > 0`. Scattered drops that never crossed the
        // sliding-window threshold produce backpressureDrops > 0 but degraded == false. No alert.
        let alert = PostStopAlert.resolve(writeError: nil, degraded: false, droppedFrames: 128)
        #expect(alert == nil)
    }

    @Test("degraded == false after acknowledge → nil (no stale alert)")
    func acknowledgedDegraded_returnsNil() {
        // Simulates the coordinator state after acknowledgeDegradedWarning() resets
        // lastSessionEverDegraded = false and lastDroppedFrames = 0.
        let alert = PostStopAlert.resolve(writeError: nil, degraded: false, droppedFrames: 0)
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
