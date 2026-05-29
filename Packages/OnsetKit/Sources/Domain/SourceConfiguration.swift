/// Capture parameters for a single `CaptureSource`.
///
/// Created by the recording session when setting up a capture pipeline. All fields
/// carry the validated, realizable values chosen by the coordinator — no validation
/// logic lives here.
///
/// - Note: Currently models video parameters (resolution/fps). Audio source parameters
///   (sample rate, channel count) are introduced with audio capture (#28).
public struct SourceConfiguration: Sendable, Equatable {
    /// The kind of source these parameters target.
    public let kind: SourceKind

    /// Pixel width of the capture output.
    public let width: Int

    /// Pixel height of the capture output.
    public let height: Int

    /// Target frames per second for video sources (ignored for audio-only sources).
    public let fps: Int

    public init(kind: SourceKind, width: Int, height: Int, fps: Int) {
        self.kind = kind
        self.width = width
        self.height = height
        self.fps = fps
    }
}
