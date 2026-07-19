import Foundation
@testable import Onset
import Testing

// MARK: - RecordingConfiguration tests

@Suite("RecordingConfiguration")
@MainActor
struct RecordingConfigurationTests {
    /// Resolved once per test instance (each @Test gets a fresh struct, re-created per
    /// Swift Testing isolation rules — no shared mutable state).
    let sut = RecordingConfiguration.mvpDefault

    // MARK: - Container / Codec / Sample Entry

    @Test("mvpDefault — container is mp4 (AC-4)")
    func mvpDefault_container_mp4() {
        #expect(self.sut.container == .mp4)
    }

    @Test("mvpDefault — codec is HEVC (AC-4)")
    func mvpDefault_codec_hevc() {
        #expect(self.sut.codec == .hevc)
    }

    @Test("mvpDefault — sampleEntry is hvc1 (AC-4)")
    func mvpDefault_sampleEntry_hvc1() {
        #expect(self.sut.sampleEntry == .hvc1)
    }

    // MARK: - Profile Level

    @Test("mvpDefault — profileLevel is mainAutoLevel")
    func mvpDefault_profileLevel_mainAutoLevel() {
        #expect(self.sut.profileLevel == .mainAutoLevel)
    }

    // MARK: - Color

    @Test("mvpDefault — colorPrimaries is Rec.709 (AC-4 SDR)")
    func mvpDefault_colorPrimaries_rec709() {
        #expect(self.sut.colorPrimaries == .rec709)
    }

    @Test("mvpDefault — transferFunction is Rec.709")
    func mvpDefault_transferFunction_rec709() {
        #expect(self.sut.transferFunction == .rec709)
    }

    @Test("mvpDefault — yCbCrMatrix is Rec.709")
    func mvpDefault_yCbCrMatrix_rec709() {
        #expect(self.sut.yCbCrMatrix == .rec709)
    }

    @Test("mvpDefault — bitDepth is 8 (AC-4)")
    func mvpDefault_bitDepth_8() {
        #expect(self.sut.bitDepth == 8)
    }

    // MARK: - Frame Rate

    @Test("mvpDefault — maxScreenFps is 60 (AC-5)")
    func mvpDefault_maxScreenFps_60() {
        #expect(self.sut.maxScreenFps == 60)
    }

    @Test("mvpDefault — minCameraFps is 30 (AC-5)")
    func mvpDefault_minCameraFps_30() {
        #expect(self.sut.minCameraFps == 30)
    }

    // MARK: - Pixel Format Preference

    @Test("mvpDefault — pixelFormatPreference is [biPlanar420v, biPlanar420f]")
    func mvpDefault_pixelFormatPreference() {
        #expect(self.sut.pixelFormatPreference == [.biPlanar420v, .biPlanar420f])
    }

    // MARK: - GOP / Reordering

    @Test("mvpDefault — allowFrameReordering is false (reorder window pins pending≥4, hits backpressure gate; #112)")
    func mvpDefault_allowFrameReordering_false() {
        #expect(self.sut.allowFrameReordering == false)
    }

    // MARK: - Movie Fragment Interval

    @Test("mvpDefault — movieFragmentInterval is 4 seconds (AC-10)")
    func mvpDefault_movieFragmentInterval_4s() {
        #expect(self.sut.movieFragmentInterval == 4.0)
    }

    // MARK: - Bitrate Table Lookup

    @Test("averageBitrate — 4K@60 returns a positive value from the table")
    func bitrateLookup_4K60_positive() {
        let bitrate = self.sut.averageBitrate(forWidth: 3840, height: 2160, fps: 60)
        #expect(bitrate > 0)
    }

    @Test("averageBitrate — 1080p@30 returns a positive value from the table")
    func bitrateLookup_1080p30_positive() {
        let bitrate = self.sut.averageBitrate(forWidth: 1920, height: 1080, fps: 30)
        #expect(bitrate > 0)
    }

    @Test("averageBitrate — unknown key returns a positive fallback")
    func bitrateLookup_unknownKey_positiveFallback() {
        // 720p@24 is not in the table; the fallback must return > 0.
        let bitrate = self.sut.averageBitrate(forWidth: 1280, height: 720, fps: 24)
        #expect(bitrate > 0)
    }

    @Test("averageBitrate — 4K@60 bitrate is higher than 1080p@30 bitrate")
    func bitrateLookup_4K60_greaterThan_1080p30() {
        let bitrate4K60 = self.sut.averageBitrate(forWidth: 3840, height: 2160, fps: 60)
        let bitrate1080p30 = self.sut.averageBitrate(forWidth: 1920, height: 1080, fps: 30)
        #expect(bitrate4K60 > bitrate1080p30)
    }

    // MARK: - Output Directory

    // UT-5: baseOutputDirectory must be rooted at the user's home directory, not just end with Movies/Onset.
    @Test("mvpDefault — baseOutputDirectory is <home>/Movies/Onset/ (UT-5)")
    func mvpDefault_baseOutputDirectory_isHomeMoviesOnset() {
        // URL(filePath:directoryHint:.isDirectory) appends a trailing slash.
        let expected = NSHomeDirectory() + "/Movies/Onset/"
        #expect(self.sut.baseOutputDirectory.path(percentEncoded: false) == expected)
    }

    // MARK: - Budget Cap

    @Test("budgetCap.maxPixelsPerSecond is 995_000_000 (spec: 4K120 ≈ 995M px/s)")
    func budgetCap_value_995M() {
        #expect(self.sut.budgetCap.maxPixelsPerSecond == 995_000_000)
    }

    @Test("makeDefault(.m3Max).budgetCap.maxPixelsPerSecond is the calibrated-floor 622_080_000")
    func makeDefault_m3Max_budgetCapValue() {
        #expect(RecordingConfiguration.makeDefault(chipTier: .m3Max).budgetCap.maxPixelsPerSecond == 622_080_000)
    }

    @Test("makeDefault(.uncalibrated).budgetCap.maxPixelsPerSecond is the safe-low 248_832_000")
    func makeDefault_uncalibrated_budgetCapValue() {
        #expect(
            RecordingConfiguration.makeDefault(chipTier: .uncalibrated).budgetCap.maxPixelsPerSecond == 248_832_000
        )
    }

    @Test("makeDefault(chipTier:) differs from mvpDefault only in budgetCap")
    func makeDefault_onlyBudgetCapDiffersFromMVPDefault() {
        let m3Config = RecordingConfiguration.makeDefault(chipTier: .m3Max)
        let ref = RecordingConfiguration.makeMVPDefault(budgetCap: m3Config.budgetCap)
        #expect(m3Config == ref)
        #expect(
            RecordingConfiguration.mvpDefault.budgetCap.maxPixelsPerSecond != m3Config.budgetCap.maxPixelsPerSecond
        )
    }

    @Test("budgetCap — 4K60 screen + 1080p30 camera fits within cap")
    func budgetCap_4K60_1080p30_fits() {
        // 4K60: 3840 × 2160 × 60 = 497,664,000
        // 1080p30: 1920 × 1080 × 30 = 62,208,000
        // Total: ~560M — well within the 995M cap.
        let fits = self.sut.budgetCap.fits(
            screen: SourceDimensions(width: 3840, height: 2160, fps: 60),
            camera: SourceDimensions(width: 1920, height: 1080, fps: 30)
        )
        #expect(fits)
    }

    @Test("budgetCap — 8K60 screen exceeds cap (over-budget scenario)")
    func budgetCap_8K60_exceeds() {
        // 8K60: 7680 × 4320 × 60 = 1,990,656,000 — almost 2× the 995M cap.
        let fits = self.sut.budgetCap.fits(
            screen: SourceDimensions(width: 7680, height: 4320, fps: 60),
            camera: SourceDimensions(width: 0, height: 0, fps: 0)
        )
        #expect(!fits)
    }

    @Test("budgetCap — 5K60 screen + 4K60 camera exceeds cap (combined over-budget)")
    func budgetCap_5K60_plus_4K60_exceeds() {
        // 5K60: 5120 × 2880 × 60 = 885,145,600
        // 4K60: 3840 × 2160 × 60 = 497,664,000
        // Total: ~1.38B — exceeds 995M.
        let fits = self.sut.budgetCap.fits(
            screen: SourceDimensions(width: 5120, height: 2880, fps: 60),
            camera: SourceDimensions(width: 3840, height: 2160, fps: 60)
        )
        #expect(!fits)
    }

    // MARK: - Camera Mirror

    @Test("mvpDefault — cameraMirror defaults to false")
    func mvpDefault_cameraMirror_false() {
        #expect(self.sut.cameraMirror == false)
    }

    /// The hand-rolled `==` must include `cameraMirror`: two configs differing ONLY in that
    /// field must compare non-equal, or change-detection silently ignores the mirror toggle.
    @Test("== treats configs differing only in cameraMirror as non-equal")
    func equality_cameraMirrorOnlyDifference_isNonEqual() {
        let unmirrored = RecordingConfiguration.makeMVPDefault(cameraMirror: false)
        let mirrored = RecordingConfiguration.makeMVPDefault(cameraMirror: true)
        #expect(unmirrored != mirrored)
    }

    /// Sanity guard for the inequality test above: two configs built with the SAME mirror value
    /// (and otherwise identical) must compare equal, so the inequality is attributable to
    /// `cameraMirror` alone.
    @Test("== treats configs with identical cameraMirror as equal")
    func equality_sameCameraMirror_isEqual() {
        let lhs = RecordingConfiguration.makeMVPDefault(cameraMirror: true)
        let rhs = RecordingConfiguration.makeMVPDefault(cameraMirror: true)
        #expect(lhs == rhs)
    }
}
