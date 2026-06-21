// PostStopAlertTests.swift
// OnsetTests
//
// Swift Testing suite for PostStopAlert.resolve(writeError:).
//
// Frame-loss is no longer surfaced as a post-stop alert (it is persisted to a per-session text
// report on disk — see DropReportFormatterTests). The only post-stop alert remaining is the
// write-error alert, so these tests cover just that single dimension.
//
@testable import Onset
import Testing

// MARK: - PostStopAlert.resolve Tests

@Suite("PostStopAlert.resolve — write-error only")
struct PostStopAlertResolveTests {
    @Test("no write error → nil")
    func noWriteError_returnsNil() {
        let alert = PostStopAlert.resolve(writeError: nil)
        #expect(alert == nil)
    }

    @Test("write error → .writeError with the reason string")
    func writeError_returnsWriteError() {
        let alert = PostStopAlert.resolve(writeError: "The disk is full.")
        guard case let .writeError(reason) = alert else {
            Issue.record("Expected .writeError, got \(String(describing: alert))")
            return
        }
        #expect(reason == "The disk is full.")
    }
}
