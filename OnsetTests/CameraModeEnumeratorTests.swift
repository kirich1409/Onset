import Foundation
@testable import Onset
import Testing

// MARK: - CameraModeEnumeratorTests

/// L2 tests for `CameraFormatSelector.availableModes(from:config:)`.
///
/// Verifies:
/// 1. One mode per distinct resolution (deduplication).
/// 2. Max policy-valid fps is used when multiple formats share the same resolution.
/// 3. Sorting — descending pixel count, fps tie-break, width tie-break.
/// 4. Empty input → empty output.
/// 5. Resolutions whose best fps is below `minCameraFps` are excluded (policy floor).
/// 6. Fps is capped to `maxScreenFps` even when the format advertises higher.
/// 7. Non-preset-backed resolutions (e.g. 1600×896) are excluded.
/// 8. Resolutions above 1080p (e.g. 4K) are excluded — AVFoundation cannot deliver them
///    from the Brio on macOS. See issue #113.
///
/// Modes are compared property-by-property, not via `==`, because under
/// `InferIsolatedConformances` the `Equatable` witness may be inferred
/// `@MainActor` even when manual `nonisolated` witnesses exist. Direct property
/// comparison bypasses any potential witness-table isolation inference.
@Suite("CameraFormatSelector.availableModes — mode enumeration")
struct CameraModeEnumeratorTests {
    // MARK: - Helpers

    private func makeFormat(width: Int32, height: Int32, maxFps: Double) -> CameraFormat {
        CameraFormat(pixelWidth: width, pixelHeight: height, minFps: 1.0, maxFps: maxFps)
    }

    // MARK: - Empty input

    @Test("Empty formats list → empty modes list")
    func emptyFormats_returnsEmptyModes() {
        let modes = CameraFormatSelector.availableModes(from: [], config: RecordingConfiguration.mvpDefault)
        #expect(modes.isEmpty)
    }

    // MARK: - Deduplication

    @Test("Two formats with same resolution → one mode at max policy-valid fps")
    func sameResolution_twoFpsOptions_oneMode() {
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1920)
        #expect(modes[0].pixelHeight == 1080)
        #expect(modes[0].fps == 60)
    }

    @Test("Three distinct resolutions including 4K → two modes (4K excluded by 1080p cap)")
    func threeDistinctResolutions_4KExcluded_twoModes() {
        // 4K is excluded — AVFoundation cannot deliver >1080p from the Brio on macOS (issue #113).
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
            self.makeFormat(width: 1280, height: 720, maxFps: 60),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 2)
    }

    // MARK: - Sorting (descending pixel count)

    @Test("Modes sorted by descending pixel count — 1080p before 720p (4K excluded)")
    func modesSortedByDescendingPixelCount() {
        // 4K is present in the format list but excluded by the 1080p cap (issue #113).
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 60), // 2.07 MP
            self.makeFormat(width: 3840, height: 2160, maxFps: 30), // 8.29 MP — excluded
            self.makeFormat(width: 1280, height: 720, maxFps: 60), // 0.92 MP
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 2)
        // 1080p first (highest pixel count within cap)
        #expect(modes[0].pixelWidth == 1920)
        #expect(modes[0].pixelHeight == 1080)
        // 720p second
        #expect(modes[1].pixelWidth == 1280)
        #expect(modes[1].pixelHeight == 720)
    }

    // MARK: - MX Brio scenario (4K@30 + 1080p@60)

    @Test("Brio-like formats [4K@30, 1080p@60, 720p@60] → modes [1080p@60, 720p@60] (4K excluded)")
    func brioLikeFormats_correctModes() {
        // 4K is excluded by the 1080p cap — AVFoundation cannot deliver 4K from the Brio on macOS
        // (uncompressed bandwidth exceeds USB; MJPEG not exposed). See issue #113.
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
            self.makeFormat(width: 1280, height: 720, maxFps: 60),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 2)
        // 1080p60 is first
        #expect(modes[0].pixelWidth == 1920 && modes[0].pixelHeight == 1080 && modes[0].fps == 60)
        // 720p60 is second
        #expect(modes[1].pixelWidth == 1280 && modes[1].pixelHeight == 720 && modes[1].fps == 60)
    }

    // MARK: - Preset-backed constraint

    @Test("Non-preset-backed resolution (1600×896) is excluded even when policy-valid")
    func nonPresetBackedResolution_excluded() {
        // 1600×896 is advertised by some built-in cameras but has no AVCaptureSession.Preset
        // on macOS. It must not appear in availableModes.
        let formats = [
            self.makeFormat(width: 1600, height: 896, maxFps: 60), // no preset — excluded
            self.makeFormat(width: 1920, height: 1080, maxFps: 60), // preset-backed — included
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1920)
        #expect(modes[0].pixelHeight == 1080)
    }

    @Test("Only non-preset-backed resolutions → empty modes list")
    func onlyNonPresetBackedResolutions_returnsEmpty() {
        // Cameras that only offer e.g. 1552×1552 (Center Stage) or other non-standard
        // sizes yield no selectable modes — the user cannot choose a mode for such cameras.
        let formats = [
            self.makeFormat(width: 1552, height: 1552, maxFps: 60), // no preset
            self.makeFormat(width: 1440, height: 1080, maxFps: 30), // no preset
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.isEmpty)
    }

    @Test("Brio-like mix with arbitrary sizes: only ≤1080p preset-backed dims included")
    func brioLikeWithArbitrarySizes_onlyPresetBackedIncluded() {
        // Simulates the Brio advertising a mix of preset-backed and arbitrary resolutions.
        // 4K is excluded by the 1080p cap (issue #113); 1600×896 has no preset.
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30), // >1080p cap — excluded
            self.makeFormat(width: 1920, height: 1080, maxFps: 60), // preset-backed ✓
            self.makeFormat(width: 1600, height: 896, maxFps: 60), // no preset — excluded
            self.makeFormat(width: 1280, height: 720, maxFps: 60), // preset-backed ✓
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 2)
        #expect(modes[0].pixelWidth == 1920 && modes[0].pixelHeight == 1080)
        #expect(modes[1].pixelWidth == 1280 && modes[1].pixelHeight == 720)
    }

    // MARK: - Policy fps band filtering

    @Test("Resolution below minCameraFps policy floor is excluded")
    func lowFpsResolution_excludedByPolicyFloor() {
        // 1080p@10 is below minCameraFps=30 — must be filtered out.
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 10), // below policy floor
            self.makeFormat(width: 1280, height: 720, maxFps: 30),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        // Only 720p@30 survives — 1080p@10 is excluded because 10 < minCameraFps(30).
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1280)
        #expect(modes[0].pixelHeight == 720)
        #expect(modes[0].fps == 30)
    }

    @Test("Resolution above maxScreenFps is clamped, not excluded")
    func highFpsResolution_clampedToMaxScreenFps() {
        // 1080p@120 is above maxScreenFps=60 — should be offered as 1080p@60, not excluded.
        let formats = [self.makeFormat(width: 1920, height: 1080, maxFps: 120)]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1920)
        #expect(modes[0].pixelHeight == 1080)
        // Clamped to maxScreenFps=60, not 120.
        #expect(modes[0].fps == 60)
    }

    @Test("All formats below policy floor → empty result")
    func allFormatsBelowPolicyFloor_returnsEmpty() {
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 10),
            self.makeFormat(width: 1280, height: 720, maxFps: 15),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.isEmpty)
    }

    // MARK: - Single format

    @Test("Single format → single mode with matching properties")
    func singleFormat_singleMode() {
        let formats = [self.makeFormat(width: 1920, height: 1080, maxFps: 30)]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1920)
        #expect(modes[0].pixelHeight == 1080)
        #expect(modes[0].fps == 30)
    }
}
