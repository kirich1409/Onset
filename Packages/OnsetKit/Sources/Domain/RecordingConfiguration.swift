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
/// Constructed by the Validator (#31); `init` is non-public so external modules cannot
/// fabricate an unvalidated configuration. The only way to obtain a value of this type is
/// through a successful validation pass.
///
/// Carries all parameters the `RecordingSessionCoordinator` needs to set up capture
/// sources and encoding writers without any further validation.
///
/// - Note: No `public init` is declared. For a `public struct`, the synthesised
///   memberwise initialiser has `internal` access by default, which is the enforcement
///   mechanism: code outside this module cannot construct a value of this type directly.
public struct RecordingConfiguration: Sendable, Equatable {
    /// Per-source capture parameters, one entry per active source.
    public let sources: [SourceConfiguration]

    /// Output file descriptors — typically one per source group (e.g. screen+audio, camera).
    public let outputs: [OutputDescriptor]

    /// Video codec to apply across all video tracks.
    public let codec: CodecKind

    /// Container format for all output files.
    public let container: ContainerKind
}
