import Foundation

// MARK: - ValidationIssue

/// Describes why a recording configuration is not realizable.
///
/// Returned by the Validator (#31) when the requested configuration cannot be fulfilled
/// by the current hardware or system state.
public enum ValidationIssue: Error, Sendable, Equatable {
    /// No video source (screen or camera) was included in the requested configuration.
    case noVideoSource

    /// The requested pixel resolution is not supported by the capture source.
    case unsupportedResolution

    /// The requested frame rate is outside the range the capture source can deliver.
    case unsupportedFrameRate

    /// The requested codec is not available on this hardware (e.g. no VideoToolbox encoder).
    case codecUnavailable

    /// The output path is not writable (missing permissions or non-existent directory).
    case outputPathNotWritable
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
