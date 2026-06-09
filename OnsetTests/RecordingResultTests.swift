import Foundation
@testable import Onset
import Testing

// MARK: - SessionOutput init? case mapping

/// Verifies that `SessionOutput.init?(screen:camera:)` maps all four input combinations
/// to the correct enum case (or `nil`), locking the exhaustive-case contract.
@Suite("SessionOutput — failable init case mapping")
struct SessionOutputInitTests {
    private let screenResult: FinishResult = .completed(url: URL(filePath: "/tmp/screen.mp4"))
    private let cameraResult: FinishResult = .completed(url: URL(filePath: "/tmp/camera.mp4"))

    @Test("screenOnly: non-nil screen + nil camera")
    func screenOnly() throws {
        let output = try #require(SessionOutput(screen: screenResult, camera: nil))
        guard case .screenOnly = output else {
            Issue.record("Expected .screenOnly, got \(output)")
            return
        }
    }

    @Test("cameraOnly: nil screen + non-nil camera")
    func cameraOnly() throws {
        let output = try #require(SessionOutput(screen: nil, camera: cameraResult))
        guard case .cameraOnly = output else {
            Issue.record("Expected .cameraOnly, got \(output)")
            return
        }
    }

    @Test("both: non-nil screen + non-nil camera")
    func both() throws {
        let output = try #require(SessionOutput(screen: screenResult, camera: cameraResult))
        guard case .both = output else {
            Issue.record("Expected .both, got \(output)")
            return
        }
    }

    @Test("nil: nil screen + nil camera → init? returns nil")
    func nilBothReturnsNil() {
        #expect(SessionOutput(screen: nil, camera: nil) == nil)
    }
}

// MARK: - RecordingResult enum cases

/// Verifies that `RecordingResult` enum cases carry the correct payloads and that all
/// computed properties derive correctly from both `.completed` and `.empty`.
@Suite("RecordingResult — enum shape and computed properties")
struct RecordingResultTests {
    private let screenURL = URL(filePath: "/tmp/screen.mp4")
    private let cameraURL = URL(filePath: "/tmp/camera.mp4")
    private let zeroDrops = DropHealthSnapshot(
        counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        sessionEverDegraded: false,
        dominantCause: .notDegraded
    )

    // MARK: .empty

    @Test(".empty carries drops and has nil screen/camera")
    func empty_dropsAndNilProjections() {
        let result = RecordingResult.empty(self.zeroDrops)
        #expect(result.drops == self.zeroDrops.counters)
        #expect(result.screen == nil)
        #expect(result.camera == nil)
        #expect(result.outputURLs.isEmpty)
        #expect(result.degradedWarning == false)
        #expect(result.hasWriteFailure == false)
        #expect(result.writeFailureReason == nil)
    }

    // MARK: .completed — drops passthrough

    @Test(".completed carries drops from the associated DropHealthSnapshot")
    func completed_dropsPassthrough() {
        let health = DropHealthSnapshot(
            counters: DropCounters(encoderBackpressureDrops: 5, captureDrops: 2, cfrNormalizationDrops: 1),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
        )
        let result = RecordingResult.completed(.screenOnly(.completed(url: self.screenURL)), health)
        #expect(result.drops == health.counters)
    }

    // MARK: degradedWarning

    @Test("degradedWarning is false when sessionEverDegraded is false (even with backpressure drops)")
    func degradedWarning_falseWhenNotEverDegraded() {
        // The key regression test: high backpressureDrops but sessionEverDegraded == false
        // means the drops were too sparse to cross the sliding-window threshold — no warning.
        let result = RecordingResult.completed(
            .screenOnly(.completed(url: self.screenURL)),
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 128, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
        )
        #expect(result.degradedWarning == false)
    }

    @Test("degradedWarning is true when sessionEverDegraded is true")
    func degradedWarning_trueWhenSessionEverDegraded() {
        let result = RecordingResult.completed(
            .screenOnly(.completed(url: self.screenURL)),
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 1, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: true,
                dominantCause: .encode
            )
        )
        #expect(result.degradedWarning == true)
    }

    @Test("degradedWarning is false for .empty when sessionEverDegraded is false (stop-before-start no-op path)")
    func degradedWarning_falseForEmpty_neverDegraded() {
        // In the stop-before-start no-op specifically, sessionEverDegraded is always false
        // because nothing ran; the instant-stop path also carries the real latch value.
        let result = RecordingResult.empty(
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
        )
        #expect(result.degradedWarning == false)
    }

    @Test(".empty is a transparent DropHealthSnapshot carrier — non-zero captureDrops pass through")
    func empty_carriesRealCaptureDrops() {
        // The instant-stop path (session ran, no writer produced output) forwards the
        // real DropMonitor snapshot, which can include capture drops that occurred
        // before the first sample reached DualFileOutputStage.
        let result = RecordingResult.empty(
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 5, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
        )
        #expect(result.drops.captureDrops == 5)
    }

    // MARK: screen / camera projections

    @Test(".completed(.screenOnly) projects screen URL, nil camera")
    func completed_screenOnly_projections() {
        let result = RecordingResult.completed(.screenOnly(.completed(url: self.screenURL)), self.zeroDrops)
        #expect(result.screen?.url == self.screenURL)
        #expect(result.camera == nil)
        #expect(result.outputURLs == [self.screenURL])
    }

    @Test(".completed(.cameraOnly) projects camera URL, nil screen")
    func completed_cameraOnly_projections() {
        let result = RecordingResult.completed(.cameraOnly(.completed(url: self.cameraURL)), self.zeroDrops)
        #expect(result.screen == nil)
        #expect(result.camera?.url == self.cameraURL)
        #expect(result.outputURLs == [self.cameraURL])
    }

    @Test(".completed(.both) projects both URLs in screen-then-camera order")
    func completed_both_projections() {
        let result = RecordingResult.completed(
            .both(screen: .completed(url: self.screenURL), camera: .completed(url: self.cameraURL)),
            self.zeroDrops
        )
        #expect(result.screen?.url == self.screenURL)
        #expect(result.camera?.url == self.cameraURL)
        #expect(result.outputURLs == [self.screenURL, self.cameraURL])
    }

    // MARK: sessionEverDegraded / dominantCause projections

    @Test("sessionEverDegraded and dominantCause project correctly from .completed")
    func completed_healthProjections() {
        let result = RecordingResult.completed(
            .screenOnly(.completed(url: self.screenURL)),
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 10, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: true,
                dominantCause: .writer
            )
        )
        #expect(result.sessionEverDegraded == true)
        #expect(result.dominantCause == .writer)
    }

    @Test("sessionEverDegraded is false and dominantCause is .notDegraded for never-degraded session")
    func completed_healthProjections_neverDegraded() {
        let result = RecordingResult.completed(
            .screenOnly(.completed(url: self.screenURL)),
            self.zeroDrops
        )
        #expect(result.sessionEverDegraded == false)
        #expect(result.dominantCause == .notDegraded)
    }

    // MARK: write failure

    @Test("hasWriteFailure is false when all writers completed")
    func hasWriteFailure_falseWhenAllCompleted() {
        let result = RecordingResult.completed(.screenOnly(.completed(url: self.screenURL)), self.zeroDrops)
        #expect(result.hasWriteFailure == false)
        #expect(result.writeFailureReason == nil)
    }

    @Test("hasWriteFailure is true and writeFailureReason is non-nil when screen writer failed")
    func hasWriteFailure_trueWhenScreenFailed() {
        struct DiskFull: Error, LocalizedError {
            var errorDescription: String? {
                "The disk is full."
            }
        }
        let result = RecordingResult.completed(
            .screenOnly(.failed(url: self.screenURL, error: DiskFull())),
            self.zeroDrops
        )
        #expect(result.hasWriteFailure == true)
        #expect(result.writeFailureReason == "The disk is full.")
    }
}
