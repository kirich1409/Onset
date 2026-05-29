import Foundation

// MARK: - CodecKind

/// Video codec to use when encoding a track.
public enum CodecKind: Sendable, Equatable {
    case hevc
    case h264
}

// MARK: - ContainerKind

/// Output container format.
public enum ContainerKind: Sendable, Equatable {
    case mov
    case mp4
}

// MARK: - OutputDescriptor

/// Describes a single output file: its location, codec, container, and the tracks it holds.
///
/// Passed to `EncodingWriter.prepare(_:)` to configure an output pipeline before recording
/// begins.
public struct OutputDescriptor: Sendable, Equatable {
    /// File-system URL at which the output file will be written.
    public let destination: URL

    /// Video codec to use for encoded video tracks.
    public let codec: CodecKind

    /// Container format for the output file.
    public let container: ContainerKind

    /// The set of tracks this file contains (e.g. `[.video]`, `[.audio]`, `[.video, .audio]`).
    ///
    /// Invariant: `tracks` must be non-empty (enforced by the Validator, #31).
    /// Using `Set` eliminates the duplicate-track illegal state representable by `[TrackKind]`.
    public let tracks: Set<TrackKind>

    public init(
        destination: URL,
        codec: CodecKind,
        container: ContainerKind,
        tracks: Set<TrackKind>
    ) {
        self.destination = destination
        self.codec = codec
        self.container = container
        self.tracks = tracks
    }
}
