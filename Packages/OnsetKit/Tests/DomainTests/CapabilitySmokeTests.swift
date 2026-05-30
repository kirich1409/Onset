import CoreMedia
import Domain
import Foundation
import Testing

// MARK: - CapabilitySnapshot smoke tests

/// Smoke tests for Domain capability value types (Capability.swift).
///
/// These tests verify that:
/// - All value types compose and round-trip correctly.
/// - `CapabilitySnapshot.generation` is preserved.
/// - `EncoderCapability.==` handles `nil` maxDimensions correctly.
///
/// ## L5 boundary
///
/// Actual device discovery, VT encoder probe, sysctl reads, and hotplug generation bumps
/// are verified by manual L5 hardware-acceptance on the reference machine
/// (see `docs/spec/testing.md` Appendix A). NOT automated in CI.
@Suite("Domain — Capability value types")
struct CapabilityValueTypeTests {

    // MARK: ChipTier

    @Test("ChipTier covers all cases via CaseIterable")
    func chipTierAllCases() {
        // CaseIterable gives us a compile-time count check.
        #expect(ChipTier.allCases.count == 5)
        #expect(ChipTier.allCases.contains(.base))
        #expect(ChipTier.allCases.contains(.pro))
        #expect(ChipTier.allCases.contains(.max))
        #expect(ChipTier.allCases.contains(.ultra))
        #expect(ChipTier.allCases.contains(.unknown))
    }

    @Test("ChipTier Equatable")
    func chipTierEquatable() {
        #expect(ChipTier.base == .base)
        #expect(ChipTier.max != .ultra)
        #expect(ChipTier.unknown != .base)
    }

    // MARK: CaptureScope

    @Test("CaptureScope.fullDisplay is Sendable and Equatable")
    func captureScopeFullDisplay() {
        let scope: CaptureScope = .fullDisplay
        #expect(scope == .fullDisplay)
    }

    // MARK: DisplayCapability

    @Test("DisplayCapability round-trips all fields")
    func displayCapabilityRoundTrip() {
        let cap = DisplayCapability(id: 1, pixelWidth: 3840, pixelHeight: 2160, maxRefreshFPS: 60.0)
        #expect(cap.id == 1)
        #expect(cap.pixelWidth == 3840)
        #expect(cap.pixelHeight == 2160)
        #expect(cap.maxRefreshFPS == 60.0)
    }

    @Test("DisplayCapability Equatable")
    func displayCapabilityEquatable() {
        let a = DisplayCapability(id: 1, pixelWidth: 2560, pixelHeight: 1440, maxRefreshFPS: 120.0)
        let b = DisplayCapability(id: 1, pixelWidth: 2560, pixelHeight: 1440, maxRefreshFPS: 120.0)
        let c = DisplayCapability(id: 2, pixelWidth: 2560, pixelHeight: 1440, maxRefreshFPS: 120.0)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: CameraFormatOption

    @Test("CameraFormatOption round-trips dimensions and fps ranges")
    func cameraFormatOptionRoundTrip() {
        let dims = CMVideoDimensions(width: 1920, height: 1080)
        let option = CameraFormatOption(
            dimensions: dims,
            fpsRanges: [(minFPS: 1.0, maxFPS: 60.0)]
        )
        #expect(option.dimensions.width == 1920)
        #expect(option.dimensions.height == 1080)
        #expect(option.fpsRanges.count == 1)
        #expect(option.fpsRanges[0].maxFPS == 60.0)
    }

    @Test("CameraFormatOption Equatable matches on dimensions and fps ranges")
    func cameraFormatOptionEquatable() {
        let dims = CMVideoDimensions(width: 3840, height: 2160)
        let a = CameraFormatOption(dimensions: dims, fpsRanges: [(minFPS: 1.0, maxFPS: 30.0)])
        let b = CameraFormatOption(dimensions: dims, fpsRanges: [(minFPS: 1.0, maxFPS: 30.0)])
        let c = CameraFormatOption(dimensions: dims, fpsRanges: [(minFPS: 1.0, maxFPS: 60.0)])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: CameraCapability

    @Test("CameraCapability round-trips uniqueID, name, and formats")
    func cameraCapabilityRoundTrip() {
        let cap = CameraCapability(
            uniqueID: "cam-001",
            localizedName: "MX Brio",
            formats: [
                CameraFormatOption(
                    dimensions: CMVideoDimensions(width: 3840, height: 2160),
                    fpsRanges: [(minFPS: 1.0, maxFPS: 30.0)]
                )
            ]
        )
        #expect(cap.uniqueID == "cam-001")
        #expect(cap.localizedName == "MX Brio")
        #expect(cap.formats.count == 1)
        #expect(cap.formats[0].dimensions.width == 3840)
    }

    // MARK: AudioCapability

    @Test("AudioCapability round-trips uniqueID and name")
    func audioCapabilityRoundTrip() {
        let cap = AudioCapability(uniqueID: "mic-001", localizedName: "Built-in Microphone")
        #expect(cap.uniqueID == "mic-001")
        #expect(cap.localizedName == "Built-in Microphone")
    }

    // MARK: EncoderCapability

    @Test("EncoderCapability Equatable handles nil maxDimensions")
    func encoderCapabilityNilDimensions() {
        let a = EncoderCapability(codec: .hevc, isHardwareAccelerated: true, maxDimensions: nil)
        let b = EncoderCapability(codec: .hevc, isHardwareAccelerated: true, maxDimensions: nil)
        #expect(a == b)
    }

    @Test("EncoderCapability Equatable distinguishes codec and HW flag")
    func encoderCapabilityEquatable() {
        let hw = EncoderCapability(codec: .hevc, isHardwareAccelerated: true)
        let sw = EncoderCapability(codec: .hevc, isHardwareAccelerated: false)
        let h264 = EncoderCapability(codec: .h264, isHardwareAccelerated: true)
        #expect(hw != sw)
        #expect(hw != h264)
    }

    // MARK: SystemCapability

    @Test("SystemCapability round-trips chipTier and performanceCoreCount")
    func systemCapabilityRoundTrip() {
        let sys = SystemCapability(chipTier: .max, performanceCoreCount: 12)
        #expect(sys.chipTier == .max)
        #expect(sys.performanceCoreCount == 12)
    }

    // MARK: CapabilitySnapshot

    @Test("CapabilitySnapshot preserves generation")
    func snapshotPreservesGeneration() {
        let snapshot = CapabilitySnapshot(
            generation: 42,
            displays: [],
            cameras: [],
            microphones: [],
            encoders: [],
            system: SystemCapability(chipTier: .unknown, performanceCoreCount: 4)
        )
        #expect(snapshot.generation == 42)
    }

    @Test("CapabilitySnapshot Equatable — different generations are not equal")
    func snapshotGenerationDistinguishes() {
        let sys = SystemCapability(chipTier: .base, performanceCoreCount: 4)
        let a = CapabilitySnapshot(
            generation: 1,
            displays: [],
            cameras: [],
            microphones: [],
            encoders: [],
            system: sys
        )
        let b = CapabilitySnapshot(
            generation: 2,
            displays: [],
            cameras: [],
            microphones: [],
            encoders: [],
            system: sys
        )
        #expect(a != b)
    }

    @Test("CapabilitySnapshot Equatable — identical snapshots are equal")
    func snapshotEqualIdentical() {
        let sys = SystemCapability(chipTier: .pro, performanceCoreCount: 8)
        let display = DisplayCapability(id: 1, pixelWidth: 1920, pixelHeight: 1080, maxRefreshFPS: 60)
        let encoder = EncoderCapability(codec: .hevc, isHardwareAccelerated: true)
        let camera = CameraCapability(uniqueID: "c1", localizedName: "FaceTime HD", formats: [])
        let mic = AudioCapability(uniqueID: "m1", localizedName: "Built-in Microphone")

        let a = CapabilitySnapshot(
            generation: 0,
            displays: [display],
            cameras: [camera],
            microphones: [mic],
            encoders: [encoder],
            system: sys
        )
        let b = CapabilitySnapshot(
            generation: 0,
            displays: [display],
            cameras: [camera],
            microphones: [mic],
            encoders: [encoder],
            system: sys
        )
        #expect(a == b)
    }
}
