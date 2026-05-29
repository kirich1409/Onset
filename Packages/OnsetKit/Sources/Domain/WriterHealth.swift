/// Coarse health indicator for an `EncodingWriter`.
///
/// Updated by the writer as it processes samples and reported to the
/// `RecordingSessionCoordinator` via `EncodingWriter.health`.
public enum WriterHealth: Sendable, Equatable {
    /// The writer is operating normally and accepting samples.
    case alive

    /// The writer has encountered an unrecoverable error and is no longer writing.
    case failed

    /// The writer completed with partial output (e.g. after an `isolateAndContinue`
    /// recovery from a source failure).
    case partial
}
