// EncoderConfigBuilderTests.swift
// OnsetTests
//
// Tests for EncoderConfigBuilder (U1 of issue #31).
//
// Framework: Swift Testing (@Test / #expect) — matches the project convention.
// All expected values are derived from RecordingConfiguration.mvpDefault by
// applying the same arithmetic the production code applies; no magic numbers.

@testable import Onset
import Testing

// swiftlint:disable no_magic_numbers
// no_magic_numbers is disabled for the whole file: these are Swift Testing structs
// (no XCTest parent class), so the rule's `test_parent_classes` exclusion in
// .swiftlint.yml does not apply; the numeric literals here are expected test data,
// not magic numbers.

// MARK: - EncoderConfigBuilderTests

@Suite("EncoderConfigBuilder")
struct EncoderConfigBuilderTests {
    // Shared configuration — the canonical MVP default, same source used in production.
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - 4K60 (exact table hit)

    /// 4K60 is in the bitrate table:
    ///   averageBitRate = 60_000_000 (60 Mbps, exact match)
    ///   peakDataRate   = 60_000_000 × 2.0 = 120_000_000 (120 Mbps)
    ///   GOP            = 2.0 s
    @Test("4K60 — rate control fields (exact table hit)")
    func build_4K60_rateControl() {
        let settings = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)

        #expect(settings.averageBitRate == 60_000_000)
        #expect(settings.peakDataRate == 120_000_000)
        #expect(settings.maxKeyFrameIntervalDurationSeconds == 2.0)
    }

    @Test("4K60 — profile and encoding flags")
    func build_4K60_profileAndFlags() {
        let settings = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)

        #expect(settings.profileLevel == .mainAutoLevel)
        #expect(settings.allowFrameReordering == true)
        #expect(settings.realTime == true)
    }

    @Test("4K60 — bit depth and Rec.709 color")
    func build_4K60_colorAndDepth() {
        let settings = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)

        #expect(settings.bitDepth == 8)
        #expect(settings.colorPrimaries == .rec709)
        #expect(settings.transferFunction == .rec709)
        #expect(settings.yCbCrMatrix == .rec709)
    }

    // MARK: - 1080p30 (exact table hit)

    /// 1080p30 is in the bitrate table:
    ///   averageBitRate = 12_000_000 (12 Mbps, exact match)
    ///   peakDataRate   = 12_000_000 × 2.0 = 24_000_000 (24 Mbps)
    ///   GOP            = 2.0 s
    @Test("1080p30 — rate control fields (exact table hit)")
    func build_1080p30_rateControl() {
        let settings = EncoderConfigBuilder.build(config: config, width: 1920, height: 1080, fps: 30)

        #expect(settings.averageBitRate == 12_000_000)
        #expect(settings.peakDataRate == 24_000_000)
        #expect(settings.maxKeyFrameIntervalDurationSeconds == 2.0)
    }

    @Test("1080p30 — profile and encoding flags")
    func build_1080p30_profileAndFlags() {
        let settings = EncoderConfigBuilder.build(config: config, width: 1920, height: 1080, fps: 30)

        #expect(settings.profileLevel == .mainAutoLevel)
        #expect(settings.allowFrameReordering == true)
        #expect(settings.realTime == true)
    }

    @Test("1080p30 — bit depth and Rec.709 color")
    func build_1080p30_colorAndDepth() {
        let settings = EncoderConfigBuilder.build(config: config, width: 1920, height: 1080, fps: 30)

        #expect(settings.bitDepth == 8)
        #expect(settings.colorPrimaries == .rec709)
        #expect(settings.transferFunction == .rec709)
        #expect(settings.yCbCrMatrix == .rec709)
    }

    // MARK: - 720p30 (fallback path — not in table)

    /// 720p30 is NOT in the bitrate table.
    ///
    /// Fallback path (same-fps bucket):
    ///   pixelCount  = 1280 × 720 = 921_600
    ///   Closest fps=30 entry by pixelCount: 1920×1080 (pixelCount=2_073_600, value=12_000_000)
    ///   ratio       = 921_600 / 2_073_600 ≈ 0.444444…
    ///   average     = Int(12_000_000 × 0.444444…) = 5_333_333  (truncated per Swift Int cast)
    ///   peak        = Int((5_333_333 × 2.0).rounded()) = 10_666_666
    @Test("720p30 — fallback bitrate path (non-standard resolution)")
    func build_720p30_fallbackBitrate() {
        let settings = EncoderConfigBuilder.build(config: config, width: 1280, height: 720, fps: 30)

        // Derived: 12_000_000 × (921_600 / 2_073_600), truncated to Int.
        #expect(settings.averageBitRate == 5_333_333)
        // Derived: Int((5_333_333 × 2.0).rounded()) = 10_666_666.
        #expect(settings.peakDataRate == 10_666_666)
        #expect(settings.maxKeyFrameIntervalDurationSeconds == 2.0)
    }

    @Test("720p30 — flags and color unchanged from config (fallback path)")
    func build_720p30_invariantFields() {
        let settings = EncoderConfigBuilder.build(config: config, width: 1280, height: 720, fps: 30)

        #expect(settings.profileLevel == .mainAutoLevel)
        #expect(settings.allowFrameReordering == true)
        #expect(settings.realTime == true)
        #expect(settings.bitDepth == 8)
        #expect(settings.colorPrimaries == .rec709)
        #expect(settings.transferFunction == .rec709)
        #expect(settings.yCbCrMatrix == .rec709)
    }

    // MARK: - Equatable

    @Test("VTEncoderSettings Equatable — same inputs produce equal outputs")
    func equatable_sameInputsAreEqual() {
        let lhs = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)
        let rhs = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)
        #expect(lhs == rhs)
    }

    @Test("VTEncoderSettings Equatable — different resolutions are not equal")
    func equatable_differentResolutionsAreNotEqual() {
        let lhs = EncoderConfigBuilder.build(config: config, width: 3840, height: 2160, fps: 60)
        let rhs = EncoderConfigBuilder.build(config: config, width: 1920, height: 1080, fps: 30)
        #expect(lhs != rhs)
    }

    // MARK: - F5: VTEncoderSettings invariant init

    /// Valid numeric invariants construct successfully. The negative cases (averageBitRate ≤ 0,
    /// peakDataRate < averageBitRate, GOP ≤ 0) trip `precondition`, which aborts the process —
    /// untestable under Swift Testing — so only the positive path is asserted here.
    @Test("VTEncoderSettings direct construction succeeds for valid numeric invariants")
    func directConstruction_validInvariantsSucceeds() {
        let settings = VTEncoderSettings(
            averageBitRate: 12_000_000,
            peakDataRate: 24_000_000,
            maxKeyFrameIntervalDurationSeconds: 2.0,
            profileLevel: .mainAutoLevel,
            allowFrameReordering: true,
            realTime: true,
            bitDepth: 8,
            colorPrimaries: .rec709,
            transferFunction: .rec709,
            yCbCrMatrix: .rec709
        )

        #expect(settings.averageBitRate == 12_000_000)
        #expect(settings.peakDataRate == 24_000_000)
        // peakDataRate >= averageBitRate invariant holds for this construction.
        #expect(settings.peakDataRate >= settings.averageBitRate)
    }
}

// swiftlint:enable no_magic_numbers
