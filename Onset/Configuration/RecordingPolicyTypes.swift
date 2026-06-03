// MARK: - Container

/// Output file container format.
///
/// Maps to AVFileType at the AVAssetWriter layer; the plain-Swift representation here
/// keeps `RecordingConfiguration` free of AVFoundation imports (purity seam).
enum Container {
    /// MPEG-4 container (.mp4). Required by AC-4.
    case mp4
}

extension Container: Equatable {
    /// Manual `nonisolated` implementation so `==` is usable from any isolation context.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are
    /// inferred as `@MainActor` (`InferIsolatedConformances`). All domain value-type enums
    /// in this project override this via manual nonisolated extensions — see `PermissionStatus`.
    nonisolated static func == (lhs: Container, rhs: Container) -> Bool {
        switch (lhs, rhs) {
        case (.mp4, .mp4):
            true
        }
    }
}

// MARK: - VideoCodec

/// Video codec family.
enum VideoCodec {
    /// High Efficiency Video Coding. Required by AC-4.
    case hevc
}

extension VideoCodec: Equatable {
    nonisolated static func == (lhs: VideoCodec, rhs: VideoCodec) -> Bool {
        switch (lhs, rhs) {
        case (.hevc, .hevc):
            true
        }
    }
}

// MARK: - HEVCSampleEntry

/// HEVC sample entry tag written to the MP4 container.
///
/// `hvc1` stores parameter sets in-band (no separate `hvcC` box at the start), which
/// gives better seek behaviour and is the required value per AC-4.
enum HEVCSampleEntry {
    case hvc1
}

extension HEVCSampleEntry: Equatable {
    nonisolated static func == (lhs: HEVCSampleEntry, rhs: HEVCSampleEntry) -> Bool {
        switch (lhs, rhs) {
        case (.hvc1, .hvc1):
            true
        }
    }
}

// MARK: - HEVCProfileLevel

/// HEVC profile / level hint.
///
/// This is a pure-Swift representation. The mapping to the VideoToolbox CFString constant
/// (e.g. `kVTProfileLevel_HEVC_Main_AutoLevel`) happens in the impure encoder layer, not
/// here. The exact constant name is marked as a Known Unknown in the spec (Open Questions)
/// and must be confirmed against the macOS 26.x VideoToolbox headers at encoder-setup time.
enum HEVCProfileLevel {
    /// HEVC Main profile, auto level — the encoder chooses the appropriate level.
    /// Required by the spec ("ProfileLevel = HEVC_Main_AutoLevel, 8-bit").
    case mainAutoLevel
}

extension HEVCProfileLevel: Equatable {
    nonisolated static func == (lhs: HEVCProfileLevel, rhs: HEVCProfileLevel) -> Bool {
        switch (lhs, rhs) {
        case (.mainAutoLevel, .mainAutoLevel):
            true
        }
    }
}

// MARK: - ColorPrimaries

/// Color primaries of the video signal.
///
/// Corresponds to ITU-T H.273 ColourPrimaries values. The encoder layer maps these to
/// the appropriate CMFormatDescription color space tags.
enum ColorPrimaries {
    /// ITU-R BT.709 primaries — standard SDR for HD/4K content. Required by AC-4.
    case rec709
}

extension ColorPrimaries: Equatable {
    nonisolated static func == (lhs: ColorPrimaries, rhs: ColorPrimaries) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - TransferFunction

/// Opto-electronic transfer function (gamma curve).
enum TransferFunction {
    /// ITU-R BT.709 transfer function — SDR. Required by AC-4.
    case rec709
}

extension TransferFunction: Equatable {
    nonisolated static func == (lhs: TransferFunction, rhs: TransferFunction) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - YCbCrMatrix

/// YCbCr colour matrix.
enum YCbCrMatrix {
    /// ITU-R BT.709 matrix. Required for SDR Rec.709 content.
    case rec709
}

extension YCbCrMatrix: Equatable {
    nonisolated static func == (lhs: YCbCrMatrix, rhs: YCbCrMatrix) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - PixelFormat

/// Pixel buffer format preference for the encoder input.
///
/// The spec requires zero-copy: IOSurface-backed CVPixelBuffers must be in an
/// encoder-compatible format. The `pixelFormatPreference` list is tried in order;
/// the first format the source can deliver is used, avoiding hidden per-frame
/// conversions (Technical Constraints section).
///
/// Maps to CVPixelFormatType constants in the encoder layer (no C-interop here):
/// - `.biPlanar420v` → kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  ("420v")
/// - `.biPlanar420f` → kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   ("420f")
enum PixelFormat {
    /// 4:2:0 bi-planar, video-range (Y [16,235], Cb/Cr [16,240]). Preferred.
    case biPlanar420v
    /// 4:2:0 bi-planar, full-range (Y/Cb/Cr [0,255]).
    case biPlanar420f
}

extension PixelFormat: Equatable {
    nonisolated static func == (lhs: PixelFormat, rhs: PixelFormat) -> Bool {
        switch (lhs, rhs) {
        case (.biPlanar420v, .biPlanar420v),
             (.biPlanar420f, .biPlanar420f):
            true

        default:
            false
        }
    }
}

// MARK: - BitrateKey

/// Lookup key into the VBR average-bitrate table.
///
/// Resolution is expressed as pixel count (width × height) + fps.
/// The encoder layer resolves a concrete pixel size to the nearest table entry.
nonisolated struct BitrateKey {
    /// Frame width in pixels.
    nonisolated let width: Int
    /// Frame height in pixels.
    nonisolated let height: Int
    /// Frames per second (integer; fractional fps not used in MVP).
    nonisolated let fps: Int

    nonisolated var pixelCount: Int {
        self.width * self.height
    }
}

// swiftformat:disable:next redundantEquatable
extension BitrateKey: Equatable {
    /// Explicit `nonisolated` operator — required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    /// The compiler infers synthesised `==` as `@MainActor`-isolated, making it unusable from
    /// `nonisolated` contexts (e.g. the bitrate-table lookup in `RecordingConfiguration`).
    nonisolated static func == (lhs: BitrateKey, rhs: BitrateKey) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.fps == rhs.fps
    }
}

// `BitrateKey` intentionally does NOT conform to `Hashable`.
// Under `InferIsolatedConformances` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, even
// manually-written `hash(into:)` extensions on a non-isolated struct cause the conformance
// itself to be inferred as `@MainActor`, which makes the conformance unusable from
// `nonisolated` contexts. The storage type in `RecordingConfiguration` is therefore
// `[(key: BitrateKey, value: Int)]` (a linear-scan array) instead of `[BitrateKey: Int]`.
// The bitrate table is small (O(10) entries), so linear lookup is negligible.

// MARK: - SourceDimensions

/// Width × height × fps for one capture source.
///
/// Used by `EngineBudgetCap.fits(screen:camera:)` to avoid a six-parameter function.
nonisolated struct SourceDimensions {
    /// Frame width in pixels.
    nonisolated let width: Int
    /// Frame height in pixels.
    nonisolated let height: Int
    /// Frames per second.
    nonisolated let fps: Int

    nonisolated var pixelRate: Int {
        self.width * self.height * self.fps
    }
}

// MARK: - EngineBudgetCap

/// The throughput ceiling of a single Apple Silicon encode engine.
///
/// Source: spec section "CapabilityProbe и pre-flight бюджет":
///     "один движок ≈ 4K120 ≈ ~995M px/s"
///
/// 4K (3840 × 2160) × 120 fps = 995,328,000 ≈ 995M px/s.
/// The default recording profile caps at ≤4K60, which is ~49.8% of this ceiling.
/// The cap is applied by CapabilityProbe before starting the session; it is NOT
/// a runtime throttle (post-MVP).
nonisolated struct EngineBudgetCap: Equatable {
    /// Maximum pixel-rate (pixels/second) the encode engine supports.
    ///
    /// Value: 995_000_000 — anchored to "4K120 ≈ ~995M px/s" in the spec.
    /// This is a placeholder to be re-validated against measurements on production hardware
    /// (M1 Air through M3 Max range).
    nonisolated let maxPixelsPerSecond: Int

    /// Returns `true` when the given screen+camera combined pixel-rate fits within this cap.
    ///
    /// - Parameters:
    ///   - screen: Screen capture dimensions (width × height × fps).
    ///   - camera: Camera capture dimensions (width × height × fps).
    nonisolated func fits(screen: SourceDimensions, camera: SourceDimensions) -> Bool {
        screen.pixelRate + camera.pixelRate <= self.maxPixelsPerSecond
    }
}
