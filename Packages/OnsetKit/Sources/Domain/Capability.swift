import CoreMedia
import Foundation

// MARK: - ChipTier

/// Apple Silicon chip tier, inferred from sysctl brand string.
///
/// Used by `CapabilityMatrix` as the key for multi-stream encode budget lookups.
/// `.unknown` is the conservative fallback when the tier cannot be determined.
public enum ChipTier: Sendable, Equatable, CaseIterable {
    /// M-series base (M1, M2, M3, M4).
    case base
    /// M-series Pro (M1 Pro, M2 Pro, M3 Pro, M4 Pro).
    case pro
    /// M-series Max (M1 Max, M2 Max, M3 Max, M4 Max).
    case max
    /// M-series Ultra (M1 Ultra, M2 Ultra, M3 Ultra, M4 Ultra).
    case ultra
    /// Could not determine the tier — apply conservative budget.
    case unknown
}

// MARK: - CaptureScope

/// Recording mode — which capture sources are active.
///
/// The current MVP scope is `.fullDisplay` (screen capture as the primary video source).
/// Phase 2 will add `.region` and `.window` variants without breaking downstream consumers.
///
/// - Note: `CaptureScope` is a Domain value type; it does not map 1:1 to `SourceKind`.
///   The coordinator derives the set of active `CaptureSource`s from the
///   `RecordingConfiguration`, which is produced by the Validator from `Selections`.
public enum CaptureScope: Sendable, Equatable {
    /// Full-display screen capture (entire pixel grid of the selected `SCDisplay`).
    case fullDisplay
    // Phase 2 — reserved for region / window scopes. Not available in MVP.
    // case region(CGRect)
    // case window
}

// MARK: - DisplayCapability

/// Describes a connected display's recording capabilities.
///
/// `id` is a `CGDirectDisplayID` (an opaque `UInt32`). `pixelWidth`/`pixelHeight` are
/// native hardware pixels from `CGDisplayCopyDisplayMode`, NOT points — Retina displays
/// expose ×2 or ×3 pixel density. `maxRefreshFPS` is the maximum refresh rate reported
/// by the display mode.
///
/// Device names are OS-provided data, not user-facing UI strings — they are exempt from
/// the NFR-I18N String-Catalog requirement.
public struct DisplayCapability: Sendable, Equatable {
    /// `CGDirectDisplayID` of the display.
    public let id: UInt32
    /// Native pixel width (from `CGDisplayCopyDisplayMode`).
    public let pixelWidth: Int
    /// Native pixel height (from `CGDisplayCopyDisplayMode`).
    public let pixelHeight: Int
    /// Maximum refresh rate in frames per second.
    public let maxRefreshFPS: Double

    public init(id: UInt32, pixelWidth: Int, pixelHeight: Int, maxRefreshFPS: Double) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.maxRefreshFPS = maxRefreshFPS
    }
}

// MARK: - CameraFormatOption

/// A single camera format option: native pixel dimensions and supported fps ranges.
///
/// Mirrors `CameraCaptureSource.FormatOption` at the capability layer, but lives in
/// Domain so `CapabilitySnapshot` can stay pure. Only combinations present in the
/// device's `AVCaptureDevice.formats` are represented — no synthesis (AC-3).
public struct CameraFormatOption: Sendable, Equatable {
    /// Native pixel dimensions of the format.
    public let dimensions: CMVideoDimensions
    /// Supported fps ranges as `(min, max)` pairs (in frames per second).
    public let fpsRanges: [(minFPS: Double, maxFPS: Double)]

    public init(dimensions: CMVideoDimensions, fpsRanges: [(minFPS: Double, maxFPS: Double)]) {
        self.dimensions = dimensions
        self.fpsRanges = fpsRanges
    }

    public static func == (lhs: CameraFormatOption, rhs: CameraFormatOption) -> Bool {
        lhs.dimensions.width == rhs.dimensions.width
            && lhs.dimensions.height == rhs.dimensions.height
            && lhs.fpsRanges.count == rhs.fpsRanges.count
            && lhs.fpsRanges.elementsEqual(rhs.fpsRanges) {
                $0.minFPS == $1.minFPS && $0.maxFPS == $1.maxFPS
            }
    }
}

// MARK: - CameraCapability

/// Describes a connected camera's recording capabilities.
///
/// `uniqueID` is `AVCaptureDevice.uniqueID` — a stable string identifier that persists
/// across hotplug cycles for the same physical device. `localizedName` is OS-provided
/// data (not a UI string — exempt from NFR-I18N String-Catalog requirement).
public struct CameraCapability: Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID` — stable hardware identifier.
    public let uniqueID: String
    /// `AVCaptureDevice.localizedName` — OS-provided device label.
    public let localizedName: String
    /// All supported format options (resolution + fps ranges).
    public let formats: [CameraFormatOption]

    public init(uniqueID: String, localizedName: String, formats: [CameraFormatOption]) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.formats = formats
    }
}

// MARK: - AudioCapability

/// Describes an available microphone / audio input device.
///
/// `uniqueID` is `AVCaptureDevice.uniqueID`; `localizedName` is OS-provided data
/// (exempt from NFR-I18N String-Catalog requirement).
public struct AudioCapability: Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID` — stable hardware identifier.
    public let uniqueID: String
    /// `AVCaptureDevice.localizedName` — OS-provided device label.
    public let localizedName: String

    public init(uniqueID: String, localizedName: String) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
    }
}

// MARK: - EncoderCapability

/// Describes a VideoToolbox encoder for a specific codec.
///
/// `isHardwareAccelerated` maps to the `kVTVideoEncoderList_IsHardwareAccelerated`
/// key in `VTCopyVideoEncoderList`'s output array. `maxDimensions` is the largest
/// pixel dimension the encoder reports as supported (nil when the encoder dict does
/// not carry an explicit maximum).
public struct EncoderCapability: Sendable, Equatable {
    /// The video codec this encoder targets.
    public let codec: CodecKind
    /// `true` when the encoder is hardware-accelerated (VideoToolbox reports
    /// `kVTVideoEncoderList_IsHardwareAccelerated == true`).
    public let isHardwareAccelerated: Bool
    /// Maximum supported pixel dimensions, or `nil` when not reported by VT.
    public let maxDimensions: CMVideoDimensions?

    public init(
        codec: CodecKind,
        isHardwareAccelerated: Bool,
        maxDimensions: CMVideoDimensions? = nil
    ) {
        self.codec = codec
        self.isHardwareAccelerated = isHardwareAccelerated
        self.maxDimensions = maxDimensions
    }

    public static func == (lhs: EncoderCapability, rhs: EncoderCapability) -> Bool {
        lhs.codec == rhs.codec
            && lhs.isHardwareAccelerated == rhs.isHardwareAccelerated
            && lhs.maxDimensions?.width == rhs.maxDimensions?.width
            && lhs.maxDimensions?.height == rhs.maxDimensions?.height
    }
}

// MARK: - SystemCapability

/// System-level capability facts derived from sysctl and process info.
///
/// `chipTier` drives `CapabilityMatrix` lookups for multi-stream encode budgets.
/// `performanceCoreCount` is the raw P-core count from `hw.perflevel0.physicalcpu`
/// — used as the conservative fallback budget when `chipTier` is `.unknown`.
public struct SystemCapability: Sendable, Equatable {
    /// Detected Apple Silicon chip tier.
    public let chipTier: ChipTier
    /// Number of performance (P) cores (`hw.perflevel0.physicalcpu`).
    /// Falls back to `ProcessInfo.processInfo.activeProcessorCount` if sysctl fails.
    public let performanceCoreCount: Int

    public init(chipTier: ChipTier, performanceCoreCount: Int) {
        self.chipTier = chipTier
        self.performanceCoreCount = performanceCoreCount
    }
}

// MARK: - CapabilitySnapshot

/// A versioned, immutable snapshot of all hardware capabilities at a point in time.
///
/// `generation` is bumped monotonically by `CapabilityService` on every rebuild or
/// hotplug event. A value of 0 means no snapshot has been built yet; the first probe
/// yields generation 1. Consumers compare generations to detect staleness without
/// diffing the entire snapshot.
///
/// All members are pure value types: `CapabilitySnapshot` itself is `Sendable` and
/// safe to pass across actor boundaries without copying.
public struct CapabilitySnapshot: Sendable, Equatable {
    /// Monotonic generation counter. 0 = no snapshot built yet; the first probe yields
    /// generation 1; monotonically bumped on each rebuild/hotplug.
    public let generation: Int
    /// Connected display capabilities (empty when Screen Recording TCC is denied).
    public let displays: [DisplayCapability]
    /// Connected camera capabilities (empty when no cameras are attached or discovered).
    public let cameras: [CameraCapability]
    /// Available microphone / audio-input capabilities.
    public let microphones: [AudioCapability]
    /// VideoToolbox encoder capabilities for HEVC and H.264.
    public let encoders: [EncoderCapability]
    /// System chip tier and core count.
    public let system: SystemCapability

    public init(
        generation: Int,
        displays: [DisplayCapability],
        cameras: [CameraCapability],
        microphones: [AudioCapability],
        encoders: [EncoderCapability],
        system: SystemCapability
    ) {
        self.generation = generation
        self.displays = displays
        self.cameras = cameras
        self.microphones = microphones
        self.encoders = encoders
        self.system = system
    }
}
