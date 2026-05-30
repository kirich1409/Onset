import CoreMedia
import Foundation

// MARK: - ValidationIssue

/// Describes a validation finding produced by the Validator (#31).
///
/// This is a plain descriptive enum — it does NOT conform to `Error`. Auto-corrections
/// (`.frameRateClamped`, `.softwareEncoderOnly`) are informational and not errors;
/// conflating them with `Error` would be type-system misdirection. Rendering issue
/// cases as user-facing strings is the responsibility of the Presentation layer (#32).
///
/// `CMVideoDimensions` is not `Equatable` in the SDK, so `==` is implemented manually
/// on this enum via field-wise comparison (same pattern as `EncoderCapability`).
public enum ValidationIssue: Sendable {
    /// No video source (screen or camera) was included in the selection.
    case noVideoSource

    /// The requested frame rate exceeded the source's maximum; it was clamped automatically.
    ///
    /// - Parameters:
    ///   - requested: The fps value from `Selections.targetFPS`.
    ///   - applied: The clamped fps actually used in the configuration.
    ///   - source: Which capture source (`.screen` or `.camera`) triggered the clamp.
    case frameRateClamped(requested: Int, applied: Int, source: SourceKind)

    /// The chosen resolution exceeds the codec encoder's reported `maxDimensions`.
    ///
    /// - Parameters:
    ///   - requested: The pixel dimensions of the active capture format.
    ///   - maxSupported: The encoder's declared maximum, or `nil` when not reported.
    ///   - codec: The codec for which the encoder was queried.
    case resolutionUnsupported(
        requested: CMVideoDimensions,
        maxSupported: CMVideoDimensions?,
        codec: CodecKind
    )

    /// No encoder (hardware or software) is available for the selected codec.
    case codecUnavailable(CodecKind)

    /// Only a software encoder exists for the chosen codec.
    ///
    /// This is a warning: recording is still permitted, but HW acceleration is absent.
    /// The Validator never silently falls back to software; this correction surfaces
    /// the state explicitly so the caller can decide.
    case softwareEncoderOnly(CodecKind)

    /// A device referenced in `Selections` is no longer present in the snapshot (TOCTOU).
    ///
    /// Re-validating against a fresh `CapabilitySnapshot` is the correct recovery.
    case deviceUnavailable(id: String, kind: SourceKind)

    /// The number of simultaneous video encode sessions exceeds the chip's hardware budget.
    ///
    /// - Parameters:
    ///   - requested: Number of simultaneous encode sessions in the selection.
    ///   - budget: Maximum supported by `CapabilityMatrix` for the detected chip tier.
    case streamBudgetExceeded(requested: Int, budget: Int)
}

extension ValidationIssue: Equatable {
    public static func == (lhs: ValidationIssue, rhs: ValidationIssue) -> Bool {
        switch (lhs, rhs) {
        case (.noVideoSource, .noVideoSource):
            return true
        case (.frameRateClamped(let lReq, let lApp, let lSrc), .frameRateClamped(let rReq, let rApp, let rSrc)):
            return lReq == rReq && lApp == rApp && lSrc == rSrc
        case (
            .resolutionUnsupported(let lReq, let lMax, let lCodec),
            .resolutionUnsupported(let rReq, let rMax, let rCodec)
        ):
            return dimensionsEqual(lReq, rReq) && optionalDimsEqual(lMax, rMax) && lCodec == rCodec
        case (.codecUnavailable(let lhs), .codecUnavailable(let rhs)):
            return lhs == rhs
        case (.softwareEncoderOnly(let lhs), .softwareEncoderOnly(let rhs)):
            return lhs == rhs
        case (.deviceUnavailable(let lID, let lKind), .deviceUnavailable(let rID, let rKind)):
            return lID == rID && lKind == rKind
        case (.streamBudgetExceeded(let lReq, let lBud), .streamBudgetExceeded(let rReq, let rBud)):
            return lReq == rReq && lBud == rBud
        default:
            return false
        }
    }

    // CMVideoDimensions is not Equatable — compare fields directly.
    private static func dimensionsEqual(_ lhs: CMVideoDimensions, _ rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    private static func optionalDimsEqual(
        _ lhs: CMVideoDimensions?, _ rhs: CMVideoDimensions?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lv?, let rv?): return dimensionsEqual(lv, rv)
        default: return false
        }
    }
}

// MARK: - ValidationOutcome

/// The result of running the Validator over a `Selections` + `CapabilitySnapshot` pair.
///
/// ## Design note — deviation from issue spec
/// The issue spec proposed `Result<RecordingConfiguration, [ValidationIssue]>` as the
/// return type, but that representation is internally inconsistent: `Result.success` has
/// no channel for warnings (e.g. `.softwareEncoderOnly`, `.frameRateClamped`), yet the
/// same spec requires those auto-corrections be visible to the caller. Using a dedicated
/// three-case enum resolves the inconsistency without losing type safety.
public enum ValidationOutcome: Sendable, Equatable {
    /// All checks passed; no auto-corrections were applied.
    case valid(RecordingConfiguration)

    /// Configuration is usable but one or more values were auto-corrected or warnings exist.
    ///
    /// - Note: `.softwareEncoderOnly` is technically a warning rather than a value correction,
    ///   but lives here because `autoCorrected` is the only outcome channel that carries both
    ///   a usable configuration and diagnostic issues simultaneously.
    case autoCorrected(RecordingConfiguration, corrections: [ValidationIssue])

    /// Configuration cannot be realized; recording must not start.
    case rejected(reasons: [ValidationIssue])

    public static func == (lhs: ValidationOutcome, rhs: ValidationOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.valid(let lCfg), .valid(let rCfg)):
            return lCfg == rCfg
        case (.autoCorrected(let lCfg, let lCorr), .autoCorrected(let rCfg, let rCorr)):
            return lCfg == rCfg && lCorr == rCorr
        case (.rejected(let lReasons), .rejected(let rReasons)):
            return lReasons == rReasons
        default:
            return false
        }
    }
}

// MARK: - RecordingConfiguration

/// A guaranteed-realizable recording configuration.
///
/// Constructed **only** by the Validator (#31, Infrastructure module). The init is
/// `package` (not `public`) so that the Validator — which lives in a separate Swift
/// module within the same OnsetKit package — can construct values of this type, while
/// external clients of OnsetKit cannot fabricate an unvalidated configuration.
///
/// The "only Validator constructs this" invariant is upheld by convention and code
/// review: other same-package targets could technically call the `package init`, but
/// only the Validator is architecturally permitted to do so.
///
/// Carries all parameters the `RecordingSessionCoordinator` needs to set up capture
/// sources and encoding writers without any further validation.
public struct RecordingConfiguration: Sendable, Equatable {
    /// Per-source capture parameters, one entry per active source.
    public let sources: [SourceConfiguration]

    /// Output file descriptors — typically one per source group (e.g. screen+audio, camera).
    ///
    /// Each descriptor carries its own `codec` and `container`; outputs may legitimately
    /// differ (e.g. the screen file uses HEVC in MOV while the camera file uses H.264 in MP4).
    /// There is no top-level codec/container on `RecordingConfiguration` — per-output is authoritative.
    public let outputs: [OutputDescriptor]

    /// Designated initialiser. `package` access lets same-package modules (i.e. the
    /// Validator in Infrastructure) construct validated configurations; public callers cannot.
    package init(
        sources: [SourceConfiguration],
        outputs: [OutputDescriptor]
    ) {
        self.sources = sources
        self.outputs = outputs
    }
}
