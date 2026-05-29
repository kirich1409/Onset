import CoreMedia

// MARK: - Kinds

/// Identifies which capture source produced a sample or maps to a writer input.
public enum SourceKind: Sendable, Equatable {
    case screen
    case camera
    case audio
}

/// Identifies the track type inside an output file.
public enum TrackKind: Sendable, Equatable {
    case video
    case audio
}

// MARK: - ClockProviding

/// Provides access to the host-time reference clock for the recording session.
///
/// The recording session owns the one canonical `ClockProviding` instance and passes it
/// into each `CaptureSource` and `EncodingWriter` so that all components share the same
/// timing reference without reaching into Infrastructure.
public protocol ClockProviding {
    /// The underlying host-time `CMClock` used as the reference for all PTS conversions.
    var referenceClock: CMClock { get }

    /// Returns the current host time as a `CMTime`.
    func now() -> CMTime

    /// Converts `time` from the `src` clock into the receiver's `referenceClock` time base.
    ///
    /// Wraps `CMSyncConvertTime`. The caller is responsible for ensuring `src` is
    /// synchronised (or can be synchronised) to `referenceClock`.
    func convert(_ time: CMTime, from src: CMClock) -> CMTime
}

// MARK: - CaptureSource

/// A source of media samples (screen, camera, or microphone).
///
/// Implementations live in Infrastructure. Domain never imports ScreenCaptureKit or
/// AVFoundation directly; this protocol is the seam that keeps the boundary clean.
public protocol CaptureSource: AnyObject {
    /// The kind of media this source captures.
    var kind: SourceKind { get }

    /// The hardware clock associated with this capture device.
    ///
    /// Used to convert device-local PTS values into the session's reference clock via
    /// `ClockProviding.convert(_:from:)`.
    var sourceClock: CMClock { get }

    /// Configures the source with the given parameters. Must be called before `start`.
    func configure(_ config: SourceConfiguration) throws

    /// Starts capturing and delivers samples to `sink`.
    func start(emittingTo sink: any SampleSink) throws

    /// Stops capturing. Must be idempotent.
    func stop()
}

// MARK: - SampleSink

/// Receives `CMSampleBuffer`s from one or more `CaptureSource`s.
///
/// Implemented by `SampleRouter` in Application. The router fans out to the writers
/// and enforces backpressure / lossless audio semantics before forwarding.
public protocol SampleSink: AnyObject {
    /// Called by a `CaptureSource` for every sample it produces.
    ///
    /// Implementations must be safe to call from a GCD capture queue; no actor
    /// isolation is assumed. Callers must retain the buffer only as long as this call;
    /// the sink is responsible for any necessary additional retention.
    func receive(_ buf: CMSampleBuffer, kind: SourceKind)
}

// MARK: - EncodingWriter

/// Encodes and writes media samples to an output container.
///
/// Implemented by `AVAssetWriterPipeline` in Infrastructure.
///
/// - Note on `isAlive` thread safety: **implementers must back this property with an
///   atomic load using acquire/release semantics** (e.g. `OSAllocatedUnfairLock` or
///   `Atomic<Bool>`) — not a lock, and not an actor-isolated stored property — because
///   `isAlive` may be polled from the recording-session control plane concurrently with
///   sample delivery callbacks. The protocol declares the requirement; enforcement is the
///   implementer's responsibility.
public protocol EncodingWriter: AnyObject {
    /// Prepares the writer for the described output. Must be called before `beginSession`.
    func prepare(_ descriptor: OutputDescriptor) throws

    /// Marks the start of the recording session at the given source time.
    func beginSession(atSourceTime time: CMTime)

    /// Appends a sample buffer to the specified track.
    func append(_ buf: CMSampleBuffer, track: TrackKind)

    /// Finalises and closes the output file. May be called from any concurrency context.
    func finalize() async throws

    /// A coarse health indicator updated by the writer as it processes samples.
    var health: WriterHealth { get }

    /// `true` as long as the writer is able to accept and process samples.
    ///
    /// Implementers must back this with an atomic load (acquire/release semantics),
    /// NOT a lock — see type-level note above.
    var isAlive: Bool { get }
}
