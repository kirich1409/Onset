import CoreMedia
import Domain
import Foundation
import Testing

@testable import Infrastructure

// MARK: - CameraCaptureSource — format-option projection tests

/// Tests for `CameraCaptureSource.projectFormatOption(description:fpsRanges:)`.
///
/// `AVCaptureDevice.Format` has no public initialiser, so these tests drive the testable
/// *core* — `projectFormatOption` — with a `CMVideoFormatDescription` built via
/// `CMVideoFormatDescriptionCreate`. This verifies:
///   - `CMVideoFormatDescriptionGetDimensions` round-trips correctly through the projection.
///   - Fps ranges are stored without modification.
///   - AC-3 invariant: only the combinations passed in are returned (no synthesis).
///
/// ## L5 boundary
///
/// Full enumeration from a live `AVCaptureDevice.Format` array, MJPEG hardware-decode
/// path, zero-copy hold time, and sustained 4K@30 / 1080p@60 / 720p@90 are verified
/// by manual L5 hardware-acceptance against a Logitech MX Brio on MacBook Pro 14" M3 Max
/// (see `docs/spec/testing.md` Appendix A). NOT automated in CI.
@Suite("CameraCaptureSource — format-option projection")
struct FormatOptionProjectionTests {

    // MARK: Helpers

    /// Builds a `CMVideoFormatDescription` with the given pixel dimensions.
    ///
    /// `CMVideoFormatDescriptionCreate` is available without a live camera; it constructs
    /// a description from a codec type and dimensions. We use `kCMVideoCodecType_H264`
    /// as a nominal codec — the codec value is irrelevant to the dimension-extraction
    /// under test.
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

    // MARK: Dimension round-trip

    @Test("projectFormatOption preserves width and height from CMFormatDescription")
    func dimensionsRoundTrip() throws {
        let desc = try Self.makeDescription(width: 3840, height: 2160)
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: [(minFPS: 1.0, maxFPS: 30.0)]
        )
        #expect(option.dimensions.width == 3840)
        #expect(option.dimensions.height == 2160)
    }

    @Test("projectFormatOption preserves 1080p dimensions")
    func dimensions1080p() throws {
        let desc = try Self.makeDescription(width: 1920, height: 1080)
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: [(minFPS: 1.0, maxFPS: 60.0)]
        )
        #expect(option.dimensions.width == 1920)
        #expect(option.dimensions.height == 1080)
    }

    @Test("projectFormatOption preserves 720p dimensions")
    func dimensions720p() throws {
        let desc = try Self.makeDescription(width: 1280, height: 720)
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: [(minFPS: 1.0, maxFPS: 90.0)]
        )
        #expect(option.dimensions.width == 1280)
        #expect(option.dimensions.height == 720)
    }

    // MARK: Fps-ranges round-trip

    @Test("projectFormatOption preserves a single fps range")
    func singleFpsRange() throws {
        let desc = try Self.makeDescription(width: 1920, height: 1080)
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: [(minFPS: 1.0, maxFPS: 60.0)]
        )
        #expect(option.fpsRanges.count == 1)
        #expect(option.fpsRanges[0].minFPS == 1.0)
        #expect(option.fpsRanges[0].maxFPS == 60.0)
    }

    @Test("projectFormatOption preserves multiple fps ranges without synthesis")
    func multipleFpsRanges() throws {
        let desc = try Self.makeDescription(width: 3840, height: 2160)
        let ranges: [(minFPS: Double, maxFPS: Double)] = [
            (minFPS: 1.0, maxFPS: 30.0),
            (minFPS: 1.0, maxFPS: 15.0),
        ]
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: ranges
        )
        // AC-3 invariant: only the supplied ranges are present — no extra combinations.
        #expect(option.fpsRanges.count == 2)
        #expect(option.fpsRanges[0].minFPS == 1.0)
        #expect(option.fpsRanges[0].maxFPS == 30.0)
        #expect(option.fpsRanges[1].minFPS == 1.0)
        #expect(option.fpsRanges[1].maxFPS == 15.0)
    }

    @Test("projectFormatOption with empty fps ranges produces empty list")
    func emptyFpsRanges() throws {
        let desc = try Self.makeDescription(width: 1280, height: 720)
        let option = CameraCaptureSource.projectFormatOption(
            description: desc,
            fpsRanges: []
        )
        // AC-3 invariant: no synthetic fps values are added.
        #expect(option.fpsRanges.isEmpty)
    }

    // MARK: AC-3 invariant: multiple formats, no synthesis

    @Test("projecting MX Brio baseline formats produces exactly the declared combinations")
    func mxBrioBaselineFormats() throws {
        // Baseline MX Brio: {4K@30, 1080p@60, 720p@90} — 4K@60 must NOT appear (AC-3).
        let inputs: [(width: Int32, height: Int32, maxFPS: Double)] = [
            (3840, 2160, 30.0),
            (1920, 1080, 60.0),
            (1280, 720, 90.0),
        ]
        let options = try inputs.map { entry -> CameraCaptureSource.FormatOption in
            let desc = try Self.makeDescription(width: entry.width, height: entry.height)
            return CameraCaptureSource.projectFormatOption(
                description: desc,
                fpsRanges: [(minFPS: 1.0, maxFPS: entry.maxFPS)]
            )
        }
        #expect(options.count == 3)
        // 4K@30 — 4K@60 must NOT appear.
        #expect(options[0].dimensions.width == 3840 && options[0].fpsRanges[0].maxFPS == 30.0)
        // 1080p@60.
        #expect(options[1].dimensions.width == 1920 && options[1].fpsRanges[0].maxFPS == 60.0)
        // 720p@90.
        #expect(options[2].dimensions.width == 1280 && options[2].fpsRanges[0].maxFPS == 90.0)
        // Verify: no synthesised 4K@60 combination exists.
        let has4K60 = options.contains {
            $0.dimensions.width == 3840 && $0.fpsRanges.contains { $0.maxFPS >= 60.0 }
        }
        #expect(!has4K60, "4K@60 must not appear — AC-3 invariant")
    }
}

// MARK: - CameraCaptureSource — fps→CMTime conversion tests

/// Tests for `CameraCaptureSource.fpsToFrameDuration(_:requested:)`.
///
/// Fully pure: no device, no session, no hardware required.
@Suite("CameraCaptureSource — fps→CMTime frame-duration mapping")
struct FpsToFrameDurationTests {

    @Test("30 fps maps to CMTime(1, 30)")
    func fps30() {
        let t = CameraCaptureSource.fpsToFrameDuration(30.0, requested: 30.0)
        #expect(t == CMTime(value: 1, timescale: 30))
    }

    @Test("60 fps maps to CMTime(1, 60)")
    func fps60() {
        let t = CameraCaptureSource.fpsToFrameDuration(60.0, requested: 60.0)
        #expect(t == CMTime(value: 1, timescale: 60))
    }

    @Test("90 fps maps to CMTime(1, 90)")
    func fps90() {
        let t = CameraCaptureSource.fpsToFrameDuration(90.0, requested: 90.0)
        #expect(t == CMTime(value: 1, timescale: 90))
    }

    @Test("requested fps clamped to available — result uses available")
    func requestedAboveAvailableClamped() {
        // available=30, requested=60 → clamp to 30
        let t = CameraCaptureSource.fpsToFrameDuration(30.0, requested: 60.0)
        #expect(t == CMTime(value: 1, timescale: 30))
    }

    @Test("requested fps below available — result uses requested")
    func requestedBelowAvailable() {
        // available=90, requested=30 → use 30
        let t = CameraCaptureSource.fpsToFrameDuration(90.0, requested: 30.0)
        #expect(t == CMTime(value: 1, timescale: 30))
    }

    @Test("zero fps is floored to 1 — produces CMTime(1, 1)")
    func zeroFpsFloored() {
        let t = CameraCaptureSource.fpsToFrameDuration(30.0, requested: 0.0)
        // max(1.0, min(0.0, 30.0)) = 1.0 → CMTime(1, 1)
        #expect(t == CMTime(value: 1, timescale: 1))
    }

    @Test("negative fps is floored to 1 — produces CMTime(1, 1)")
    func negativeFpsFloored() {
        let t = CameraCaptureSource.fpsToFrameDuration(30.0, requested: -10.0)
        #expect(t == CMTime(value: 1, timescale: 1))
    }
}

// MARK: - CameraCaptureSource — selectFormat pure-logic tests

/// Tests for the pure logic in `CameraCaptureSource.selectFormat`.
///
/// `AVCaptureDevice.Format` has no public initialiser, so this suite tests the
/// fps→CMTime mapping exposed by `fpsToFrameDuration` (the core of `selectFormat`'s
/// fps-matching logic) plus the error path that fires when the formats array is empty.
/// The full `selectFormat` is covered at L5 with a live device.
@Suite("CameraCaptureSource — selectFormat pure logic")
struct SelectFormatPureLogicTests {

    @Test("selectFormat throws noCompatibleFormat when formats array is empty")
    func emptyFormatsThrows() throws {
        #expect(throws: CameraCaptureError.noCompatibleFormat) {
            _ = try CameraCaptureSource.selectFormat(
                from: [],
                width: 1920,
                height: 1080,
                fps: 30
            )
        }
    }

    @Test("fpsToFrameDuration: requested above available is clamped (pure logic)")
    func fpsClampedToAvailableViaDuration() {
        // Validates that the fps-clamping in fpsToFrameDuration is the same
        // logic selectFormat delegates to for the frame-duration calculation.
        let duration = CameraCaptureSource.fpsToFrameDuration(30.0, requested: 60.0)
        // 60 > 30 → clamped to 30 → CMTime(1, 30)
        #expect(duration == CMTime(value: 1, timescale: 30))
    }
}
