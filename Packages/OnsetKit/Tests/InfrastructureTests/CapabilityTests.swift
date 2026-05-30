import CoreMedia
import Domain
import Foundation
import Testing
import VideoToolbox

@testable import Infrastructure

// MARK: - CapabilityMatrix — classifyChipTier tests

/// Tests for `CapabilityMatrix.classifyChipTier(brand:)`.
///
/// Fully pure: no sysctl call, no device, no hardware required.
///
/// ## L5 boundary
///
/// Live sysctl reads, real VT-probe on reference hardware (MacBook Pro 14" M3 Max),
/// SCShareableContent display enumeration, and actual hotplug generation bumps are
/// verified by manual L5 hardware-acceptance (see `docs/spec/testing.md` Appendix A).
/// NOT automated in CI.
@Suite("CapabilityMatrix — chip tier classification")
struct ChipTierClassificationTests {

    // MARK: Known tiers

    @Test("Apple M3 Max → .max")
    func m3Max() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M3 Max") == .max)
    }

    @Test("Apple M3 Pro → .pro")
    func m3Pro() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M3 Pro") == .pro)
    }

    @Test("Apple M3 → .base")
    func m3Base() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M3") == .base)
    }

    @Test("Apple M3 Ultra → .ultra")
    func m3Ultra() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M3 Ultra") == .ultra)
    }

    @Test("Apple M2 Ultra → .ultra")
    func m2Ultra() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M2 Ultra") == .ultra)
    }

    @Test("Apple M2 Max → .max")
    func m2Max() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M2 Max") == .max)
    }

    @Test("Apple M2 Pro → .pro")
    func m2Pro() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M2 Pro") == .pro)
    }

    @Test("Apple M2 → .base")
    func m2Base() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M2") == .base)
    }

    @Test("Apple M1 Max → .max")
    func m1Max() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M1 Max") == .max)
    }

    @Test("Apple M4 Pro → .pro")
    func m4Pro() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M4 Pro") == .pro)
    }

    @Test("Apple M4 → .base")
    func m4Base() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M4") == .base)
    }

    @Test("Apple M4 Ultra → .ultra")
    func m4Ultra() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M4 Ultra") == .ultra)
    }

    @Test("Apple M1 Pro → .pro")
    func m1Pro() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M1 Pro") == .pro)
    }

    @Test("Apple M1 → .base")
    func m1Base() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple M1") == .base)
    }

    // MARK: Unknown / non-Apple

    @Test("empty string → .unknown")
    func emptyString() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "") == .unknown)
    }

    @Test("non-Apple brand string → .unknown")
    func nonAppleBrand() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "GenuineIntel") == .unknown)
        #expect(CapabilityMatrix.classifyChipTier(brand: "AuthenticAMD Ryzen 9") == .unknown)
    }

    @Test("Intel brand string → .unknown")
    func intelBrand() {
        #expect(
            CapabilityMatrix.classifyChipTier(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz")
                == .unknown
        )
    }

    @Test("unrecognized Apple brand → .unknown conservative fallback")
    func unknownAppleBrand() {
        // Hypothetical future chip format not yet in the matrix.
        #expect(CapabilityMatrix.classifyChipTier(brand: "Apple SomeNewSilicon") == .unknown)
    }

    @Test("case-insensitive matching — 'apple m3 max' lowercase → .max")
    func caseInsensitive() {
        #expect(CapabilityMatrix.classifyChipTier(brand: "apple m3 max") == .max)
    }
}

// MARK: - CapabilityMatrix — tier budget lookup tests

/// Tests for `CapabilityMatrix.budget(for:)`.
///
/// Verifies the data table is internally consistent and that `.unknown` returns the
/// conservative single-engine budget.
@Suite("CapabilityMatrix — tier → budget")
struct TierBudgetTests {

    @Test("base tier has single encode session and MJPEG slot")
    func baseBudget() {
        let b = CapabilityMatrix.budget(for: .base)
        #expect(b.maxHardwareEncodeSessions == 1)
        #expect(b.mjpegDecodeSlots == 1)
    }

    @Test("pro tier has dual encode sessions and MJPEG slots")
    func proBudget() {
        let b = CapabilityMatrix.budget(for: .pro)
        #expect(b.maxHardwareEncodeSessions == 2)
        #expect(b.mjpegDecodeSlots == 2)
    }

    @Test("max tier has dual encode sessions (same dual-engine as Pro)")
    func maxBudget() {
        let b = CapabilityMatrix.budget(for: .max)
        #expect(b.maxHardwareEncodeSessions == 2)
        #expect(b.mjpegDecodeSlots == 2)
    }

    @Test("ultra tier has four encode sessions (two Max dies)")
    func ultraBudget() {
        let b = CapabilityMatrix.budget(for: .ultra)
        #expect(b.maxHardwareEncodeSessions == 4)
        #expect(b.mjpegDecodeSlots == 4)
    }

    @Test("unknown tier applies conservative single-engine fallback")
    func unknownBudget() {
        let b = CapabilityMatrix.budget(for: .unknown)
        #expect(b.maxHardwareEncodeSessions == 1)
        #expect(b.mjpegDecodeSlots == 1)
    }

    @Test("unknown tier budget matches base tier budget (both conservative)")
    func unknownMatchesBase() {
        // Architecture invariant: conservative fallback must never exceed the
        // single-engine base budget.
        let unknown = CapabilityMatrix.budget(for: .unknown)
        let base = CapabilityMatrix.budget(for: .base)
        #expect(unknown.maxHardwareEncodeSessions <= base.maxHardwareEncodeSessions)
        #expect(unknown.mjpegDecodeSlots <= base.mjpegDecodeSlots)
    }

    @Test("encode session count is non-decreasing from base to ultra")
    func budgetMonotonicity() {
        // Tier order: base < pro < max < ultra.
        // The encode session count should not decrease as tier increases.
        let base = CapabilityMatrix.budget(for: .base).maxHardwareEncodeSessions
        let pro = CapabilityMatrix.budget(for: .pro).maxHardwareEncodeSessions
        let max = CapabilityMatrix.budget(for: .max).maxHardwareEncodeSessions
        let ultra = CapabilityMatrix.budget(for: .ultra).maxHardwareEncodeSessions
        #expect(base <= pro)
        #expect(pro <= max)
        #expect(max <= ultra)
    }

    @Test("all tiers produce positive maxScreenCaptureMpps")
    func mppsPositive() {
        for tier in ChipTier.allCases {
            let b = CapabilityMatrix.budget(for: tier)
            #expect(b.maxScreenCaptureMpps > 0, "tier=\(tier)")
        }
    }

    @Test("maxScreenCaptureMpps is non-decreasing from base to ultra")
    func mppsMonotonicity() {
        // Tier order: base ≤ pro ≤ max ≤ ultra (pro == max is permitted — same dual-engine).
        let base = CapabilityMatrix.budget(for: .base).maxScreenCaptureMpps
        let pro = CapabilityMatrix.budget(for: .pro).maxScreenCaptureMpps
        let max = CapabilityMatrix.budget(for: .max).maxScreenCaptureMpps
        let ultra = CapabilityMatrix.budget(for: .ultra).maxScreenCaptureMpps
        #expect(base <= pro)
        #expect(pro <= max)
        #expect(max <= ultra)
    }
}

// MARK: - CapabilityService — encoder dict mapping tests

/// Tests for `CapabilityService.encoderCapability(from:)`.
///
/// The pure mapping of a VideoToolbox encoder dict → `EncoderCapability` is testable
/// without calling live VT APIs by supplying a synthesized dictionary.
@Suite("CapabilityService — encoder dict → EncoderCapability")
struct EncoderDictMappingTests {

    // MARK: HEVC

    @Test("HEVC HW encoder dict → EncoderCapability(.hevc, isHW: true)")
    func hevcHardware() {
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: NSNumber(value: kCMVideoCodecType_HEVC),
            kVTVideoEncoderList_IsHardwareAccelerated as String: true,
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap?.codec == .hevc)
        #expect(cap?.isHardwareAccelerated == true)
        #expect(cap?.maxDimensions == nil)
    }

    @Test("HEVC SW encoder dict → EncoderCapability(.hevc, isHW: false)")
    func hevcSoftware() {
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: NSNumber(value: kCMVideoCodecType_HEVC),
            kVTVideoEncoderList_IsHardwareAccelerated as String: false,
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap?.codec == .hevc)
        #expect(cap?.isHardwareAccelerated == false)
    }

    // MARK: H.264

    @Test("H.264 HW encoder dict → EncoderCapability(.h264, isHW: true)")
    func h264Hardware() {
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: NSNumber(value: kCMVideoCodecType_H264),
            kVTVideoEncoderList_IsHardwareAccelerated as String: true,
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap?.codec == .h264)
        #expect(cap?.isHardwareAccelerated == true)
    }

    // MARK: Missing / unknown codec

    @Test("unknown codec type → nil (skipped)")
    func unknownCodecSkipped() {
        // ProRes (kCMVideoCodecType_AppleProRes422) is not a target codec.
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: NSNumber(value: UInt32(0x6170_7631)),  // 'apv1'
            kVTVideoEncoderList_IsHardwareAccelerated as String: true,
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap == nil)
    }

    @Test("missing codec type key → nil (skipped)")
    func missingCodecKey() {
        let dict: [String: Any] = [
            kVTVideoEncoderList_IsHardwareAccelerated as String: true
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap == nil)
    }

    @Test("missing IsHardwareAccelerated key → defaults to false")
    func missingHWKey() {
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: NSNumber(value: kCMVideoCodecType_HEVC)
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap?.isHardwareAccelerated == false)
    }

    @Test("empty dict → nil (skipped)")
    func emptyDict() {
        let cap = CapabilityService.encoderCapability(from: [:])
        #expect(cap == nil)
    }

    @Test("codec key present but wrong type (String) → nil (skipped)")
    func codecKeyWrongType() {
        // The codec key must be an NSNumber; a String value should not be cast-able and
        // must produce nil rather than crashing or silently returning a default.
        let dict: [String: Any] = [
            kVTVideoEncoderList_CodecType as String: "hvc1",  // String, not NSNumber
            kVTVideoEncoderList_IsHardwareAccelerated as String: true,
        ]
        let cap = CapabilityService.encoderCapability(from: dict)
        #expect(cap == nil)
    }
}

// MARK: - CapabilityService — camera format projection tests

/// Tests for the camera format projection in `CapabilityService.discoverCameras()`.
///
/// `AVCaptureDevice.Format` has no public initialiser — the live enumeration path is L5.
/// The projection logic (dimensions + fps from `CMVideoFormatDescription`) is shared with
/// `CameraCaptureSource.projectFormatOption` (already tested there). This suite verifies
/// `CameraFormatOption` construction with `CMVideoFormatDescriptionCreate`.
@Suite("CapabilityService — camera format option construction")
struct CapabilityCameraFormatTests {

    /// Builds a `CMVideoFormatDescription` for testing (mirrors CameraCaptureSourceTests).
    private static func makeDescription(width: Int32, height: Int32) throws -> CMFormatDescription {
        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        #expect(status == noErr, "CMVideoFormatDescriptionCreate failed: \(status)")
        return try #require(desc)
    }

    @Test("CameraFormatOption preserves 4K dimensions from CMFormatDescription")
    func format4KDimensions() throws {
        let desc = try Self.makeDescription(width: 3840, height: 2160)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let option = CameraFormatOption(
            dimensions: dims,
            fpsRanges: [(minFPS: 1.0, maxFPS: 30.0)]
        )
        #expect(option.dimensions.width == 3840)
        #expect(option.dimensions.height == 2160)
    }

    @Test("CameraFormatOption preserves 1080p fps ranges")
    func format1080pFpsRanges() throws {
        let desc = try Self.makeDescription(width: 1920, height: 1080)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let option = CameraFormatOption(
            dimensions: dims,
            fpsRanges: [(minFPS: 1.0, maxFPS: 60.0), (minFPS: 30.0, maxFPS: 90.0)]
        )
        #expect(option.fpsRanges.count == 2)
        #expect(option.fpsRanges[0].maxFPS == 60.0)
        #expect(option.fpsRanges[1].maxFPS == 90.0)
    }

    @Test("CameraFormatOption with empty fps ranges is valid (edge case)")
    func formatEmptyFpsRanges() throws {
        let desc = try Self.makeDescription(width: 1280, height: 720)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let option = CameraFormatOption(dimensions: dims, fpsRanges: [])
        #expect(option.fpsRanges.isEmpty)
    }
}
