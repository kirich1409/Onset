import Foundation
@testable import Onset
import Testing

// MARK: - CameraFormatSelector tests

/// `CameraFormat: Equatable` carries a `@MainActor`-inferred protocol witness under
/// `InferIsolatedConformances`. Comparing two `CameraFormat` values via `==` in a
/// `nonisolated` test context (all `@Test` methods in a struct suite are nonisolated)
/// would fail to compile. Tests bypass the witness table by comparing individual stored
/// properties directly — the same technique used by `CameraDevice: Equatable` in
/// `CaptureDeviceModels.swift`.
@Suite("CameraFormatSelector")
struct CameraFormatSelectorTests {
    // MARK: - Helpers

    /// Builds a `CameraFormat` from convenient parameters.
    private func format(
        width: Int32,
        height: Int32,
        minFps: Double = 1.0,
        maxFps: Double
    )
    -> CameraFormat {
        CameraFormat(pixelWidth: width, pixelHeight: height, minFps: minFps, maxFps: maxFps)
    }

    // MARK: - Primary selection rule

    @Test("Largest resolution among ≥30fps formats wins (AC-5)")
    func largestResolutionAmongQualifiedWins() throws {
        // 4K@30 wins over 1080p@60 and 720p@120 by pixel count.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 30), // 4K@30 — largest resolution
            format(width: 1920, height: 1080, maxFps: 60), // 1080p@60
            format(width: 1280, height: 720, maxFps: 120), // 720p@120
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 3840)
        #expect(best.pixelHeight == 2160)
        #expect(best.maxFps == 30)
    }

    // MARK: - Tie-break rule

    @Test("Same resolution: larger maxFps wins")
    func tieBreakOnFps() throws {
        // Both are 1080p; the 60fps format wins the tie-break.
        let formats = [
            format(width: 1920, height: 1080, maxFps: 30),
            format(width: 1920, height: 1080, maxFps: 60),
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 60)
    }

    // MARK: - Threshold boundary

    @Test("Format with maxFps just below 30 is excluded (NTSC 29.97 excluded by design)")
    func formatBelowThresholdExcluded() throws {
        // 4K@24 must be excluded even though it's the largest resolution.
        // 1080p@30 is the only qualifying format.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 24), // excluded: <30fps
            format(width: 1920, height: 1080, maxFps: 30), // qualifies
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 30)
    }

    @Test("Format with maxFps exactly at threshold (30.0) qualifies")
    func formatAtExactThresholdQualifies() throws {
        let formats = [
            format(width: 1920, height: 1080, maxFps: 30.0),
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 30.0)
    }

    // MARK: - All formats below threshold → throw

    @Test("Camera with only <30fps formats throws noSuitableCameraFormat (AC-5 invariant)")
    func allFormatsSubThresholdThrows() {
        // `#expect(throws: error)` requires `E: Equatable & Sendable`, but
        // `RecordingError: Equatable` is `@MainActor`-inferred under
        // `InferIsolatedConformances` — the value form is unavailable here.
        // Use the type form + pattern-match the case explicitly.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 24),
            format(width: 1920, height: 1080, maxFps: 15),
        ]
        let thrown = #expect(throws: RecordingError.self) {
            try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        }
        if case .noSuitableCameraFormat = thrown {} else {
            Issue.record("Expected .noSuitableCameraFormat, got \(String(describing: thrown))")
        }
    }

    // MARK: - Empty list → throw

    @Test("Empty format list throws noSuitableCameraFormat")
    func emptyListThrows() {
        let thrown = #expect(throws: RecordingError.self) {
            try CameraFormatSelector.pickBestFormat(from: [], minFps: 30)
        }
        if case .noSuitableCameraFormat = thrown {} else {
            Issue.record("Expected .noSuitableCameraFormat, got \(String(describing: thrown))")
        }
    }

    // MARK: - Realistic mix

    @Test("Realistic mix: built-in 1080p/720p + external Brio 4K30 → picks Brio 4K30")
    func realisticMixPicksBrio4K30() throws {
        // Simulates a MacBook with a built-in FaceTime camera (720p@30, 1080p@30)
        // plus a connected Logitech Brio (4K@30). Expected winner: Brio 4K@30.
        let formats = [
            format(width: 1280, height: 720, maxFps: 30), // built-in 720p@30
            format(width: 1920, height: 1080, maxFps: 30), // built-in 1080p@30
            format(width: 3840, height: 2160, maxFps: 30), // Brio 4K@30 — largest
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 3840)
        #expect(best.pixelHeight == 2160)
        #expect(best.maxFps == 30)
    }
}

