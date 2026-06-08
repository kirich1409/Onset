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

    @Test("Three distinct resolutions → three modes")
    func threeDistinctResolutions_threeModes() {
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
            self.makeFormat(width: 1280, height: 720, maxFps: 60),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 3)
    }

    // MARK: - Sorting (descending pixel count)

    @Test("Modes sorted by descending pixel count — 4K before 1080p")
    func modesSortedByDescendingPixelCount() {
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 60), // 2.07 MP
            self.makeFormat(width: 3840, height: 2160, maxFps: 30), // 8.29 MP
            self.makeFormat(width: 1280, height: 720, maxFps: 60), // 0.92 MP
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 3)
        // 4K first
        #expect(modes[0].pixelWidth == 3840)
        #expect(modes[0].pixelHeight == 2160)
        // 1080p second
        #expect(modes[1].pixelWidth == 1920)
        #expect(modes[1].pixelHeight == 1080)
        // 720p third
        #expect(modes[2].pixelWidth == 1280)
        #expect(modes[2].pixelHeight == 720)
    }

    // MARK: - MX Brio scenario (4K@30 + 1080p@60)

    @Test("Brio-like formats [4K@30, 1080p@60, 720p@60] → modes [4K@30, 1080p@60, 720p@60]")
    func brioLikeFormats_correctModes() {
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
            self.makeFormat(width: 1280, height: 720, maxFps: 60),
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        #expect(modes.count == 3)
        // 4K30 is first (highest pixel count)
        #expect(modes[0].pixelWidth == 3840 && modes[0].pixelHeight == 2160 && modes[0].fps == 30)
        // 1080p60 is second
        #expect(modes[1].pixelWidth == 1920 && modes[1].pixelHeight == 1080 && modes[1].fps == 60)
        // 720p60 is third
        #expect(modes[2].pixelWidth == 1280 && modes[2].pixelHeight == 720 && modes[2].fps == 60)
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
