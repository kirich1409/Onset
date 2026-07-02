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

    // MARK: - 16:9 preference over square / non-16:9

    @Test("Square 1552×1552@60 loses to 1920×1080@30 — 16:9 preferred over larger pixel count")
    func squareFormatLosesToSixteenByNine() throws {
        // The square format has more pixels (2.41 MP vs 2.07 MP) but is not 16:9.
        // Selector must return 1920×1080, not 1552×1552.
        let formats = [
            format(width: 1552, height: 1552, maxFps: 60), // Center-Stage square — NOT 16:9
            format(width: 1920, height: 1080, maxFps: 30), // 16:9 — wins despite fewer pixels
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 30)
    }

    // MARK: - Only 720p 16:9 available

    @Test("Only 1280×720@30 16:9 → returns 720p")
    func onlySingleSixteenByNineReturnsIt() throws {
        let formats = [
            format(width: 1280, height: 720, maxFps: 30),
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1280)
        #expect(best.pixelHeight == 720)
        #expect(best.maxFps == 30)
    }

    // MARK: - Full HD cap: never pick above 1080p when ≤1080p 16:9 exists

    @Test("4K@30 + 1080p@30 → picks 1080p (capped at Full HD)")
    func fourKLosesToFullHD() throws {
        // Even though 4K is 16:9 and has more pixels, 1080p is the preferred target.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 30), // 4K 16:9
            format(width: 1920, height: 1080, maxFps: 30), // 1080p 16:9 — wins (≤ 1080p)
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 30)
    }

    // MARK: - Fps tie-break on same resolution

    @Test("1920×1080@30 vs 1920×1080@60 → returns the @60 one")
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

    // MARK: - All 16:9 above 1080p → pick smallest

    @Test("Only above-1080p 16:9 formats → picks smallest (2560×1440 over 3840×2160)")
    func allSixteenByNineAboveFullHDPicksSmallest() throws {
        // Camera offers no ≤ 1080p 16:9 option — fall back to closest from above.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 30), // 4K — larger, not picked
            format(width: 2560, height: 1440, maxFps: 30), // 1440p — smallest above target, wins
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 2560)
        #expect(best.pixelHeight == 1440)
        #expect(best.maxFps == 30)
    }

    @Test("All above-1080p 16:9, same resolution different fps → fps tie-break picks @60")
    func allAboveFullHDSameResolutionPicksHigherFps() throws {
        // Both 2560×1440 formats are 16:9 and above 1080p — smallestByPixelCount branch.
        // Equal pixel counts; fps tie-break must return the @60 one.
        let formats = [
            format(width: 2560, height: 1440, maxFps: 30),
            format(width: 2560, height: 1440, maxFps: 60),
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 2560)
        #expect(best.pixelHeight == 1440)
        #expect(best.maxFps == 60)
    }

    // MARK: - Fallback: no 16:9 at all → largest pixel count

    @Test("No 16:9 formats: 1552×1552@60 + 1440×1440@30 → fallback picks largest pixel count")
    func noSixteenByNineFallsBackToLargestPixelCount() throws {
        // Neither format is 16:9 — selector falls back to the original max-pixel rule.
        let formats = [
            format(width: 1552, height: 1552, maxFps: 60), // 2.41 MP — wins by pixel count
            format(width: 1440, height: 1440, maxFps: 30), // 2.07 MP
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1552)
        #expect(best.pixelHeight == 1552)
        #expect(best.maxFps == 60)
    }

    // MARK: - Threshold boundary

    @Test("Format with maxFps just below 30 is excluded (NTSC 29.97 excluded by design)")
    func formatBelowThresholdExcluded() throws {
        // 4K@24 must be excluded even though it's the largest resolution.
        // 1080p@30 is the only qualifying format.
        let formats = [
            format(width: 3840, height: 2160, maxFps: 24), // excluded: < 30fps
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

    @Test("Realistic mix: 720p@30 + 1080p@30 + 4K@30 → picks 1080p (Full HD cap, all 16:9)")
    func realisticMixPicksFullHD() throws {
        // Simulates a camera advertising multiple 16:9 resolutions. 1080p wins because
        // it is the largest 16:9 format at or below the Full HD cap.
        let formats = [
            format(width: 1280, height: 720, maxFps: 30), // 720p 16:9
            format(width: 1920, height: 1080, maxFps: 30), // 1080p 16:9 — wins
            format(width: 3840, height: 2160, maxFps: 30), // 4K 16:9 — above cap
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
        #expect(best.maxFps == 30)
    }

    // MARK: - allowAboveFullHD: selector behaviour when caller explicitly opts in to >1080p

    // The record path passes allowAboveFullHD: true (resolveCameraFormat in
    // MainViewModel+Record.swift) — these two tests document the selector's lifted-cap
    // behaviour at the value level, independent of the caller.

    @Test("allowAboveFullHD true with 4K, 1080p and 720p available — picks 4K over the rest")
    func allowAboveFullHD_4KAvailable_picks4KOver1080p() throws {
        // Proves the cap is lifted: 4K must win over the ≤1080p options that would
        // have been chosen under the default (false) behaviour.
        //
        // This is also the record path's exact scenario: resolveCameraFormat
        // (MainViewModel+Record.swift) calls pickBestFormat with allowAboveFullHD: true, and
        // the camera encoder is built from this same resolved format's dimensions
        // (CapabilityResolver → RecordingComponentFactories), so there is no upscale mismatch.
        //
        // PR #281 previously capped this path at 1080p after observing camera stutter under
        // 4K, attributing it to AVFoundation delivering only 1080p from the Brio. A live L5
        // spike (2026-07-02, MX Brio) traced the stutter to a VT-session/format mismatch
        // artifact instead: recording native 4K camera + 4K60 screen produced zero frame loss,
        // including under worst-case full-screen motion. See
        // docs/quality/production-quality-bar.md §5.
        let formats = [
            format(width: 1280, height: 720, maxFps: 30), // 720p  16:9
            format(width: 1920, height: 1080, maxFps: 30), // 1080p 16:9 — would win with default cap
            format(width: 3840, height: 2160, maxFps: 30), // 4K    16:9 — wins when cap lifted
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30, allowAboveFullHD: true)
        #expect(best.pixelWidth == 3840)
        #expect(best.pixelHeight == 2160)
    }

    @Test("allowAboveFullHD true with no 4K available — picks largest available (1080p)")
    func allowAboveFullHD_no4K_picksLargestAvailable() throws {
        // When the camera has no 4K format the lifted cap still returns the best
        // available resolution — not an error.
        let formats = [
            format(width: 1280, height: 720, maxFps: 30), // 720p 16:9
            format(width: 1920, height: 1080, maxFps: 30), // 1080p 16:9 — wins (largest)
        ]
        let best = try CameraFormatSelector.pickBestFormat(from: formats, minFps: 30, allowAboveFullHD: true)
        #expect(best.pixelWidth == 1920)
        #expect(best.pixelHeight == 1080)
    }
}
