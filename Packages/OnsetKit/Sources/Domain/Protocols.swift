import CoreMedia

// MARK: - Kinds

/// Identifies which capture source produced a sample or maps to a writer input.
public enum SourceKind: Sendable, Equatable {
    case screen
    case camera
    case audio
}

/// Identifies the track type inside an output file.
public enum TrackKind: Sendable, Equatable, Hashable {
    case video
    case audio
}

// MARK: - ClockProviding

/// Provides access to the host-time reference clock for the recording session.
///
/// The recording session owns the one canonical `ClockProviding` instance and passes it
/// into each `CaptureSource` and `EncodingWriter` so that all components share the same
/// timing reference without reaching into Infrastructure.
///
/// Implementers are responsible for their own thread-safety (typically backed by
/// `CMClockGetHostTimeClock()` which is already safe to call from any thread).
public protocol ClockProviding: Sendable {
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
///
/// Implementers are responsible for their own thread-safety. Capture callbacks run on
/// dedicated GCD serial queues (`com.app.capture.{screen,camera,audio}`); implementers
/// must not introduce actor hops on the hot sample path.
public protocol CaptureSource: AnyObject, Sendable {
    /// The kind of media this source captures.
    var kind: SourceKind { get }

    /// The hardware clock associated with this capture device.
    ///
    /// Used to convert device-local PTS values into the session's reference clock via
    /// `ClockProviding.convert(_:from:)`.
    var sourceClock: CMClock { get }

    /// Configures the source with the given parameters. Must be called before `start`.
    ///
    /// Synchronous: performs only local property setup (no I/O, no SCK/AVFoundation
    /// async calls). The async work (content fetch, stream start) is deferred to `start`.
    func configure(_ config: SourceConfiguration) throws

    /// Starts capturing and delivers samples to `sink`.
    ///
    /// Async to allow await-ing platform-level I/O (e.g. `SCShareableContent.current`,
    /// `SCStream.startCapture()`) without blocking a Swift-concurrency cooperative thread.
    /// Blocking on these calls from a sync context (via `DispatchSemaphore`) can stall the
    /// cooperative thread pool and cause priority inversion when called from an actor.
    ///
    /// - Parameter sink: The downstream sample router that receives captured buffers.
    /// - Throws: Implementation-specific errors (e.g. `ScreenCaptureError`, permission errors).
    func start(emittingTo sink: any SampleSink) async throws

    /// Stops capturing. Must be idempotent.
    ///
    /// Async to allow await-ing the platform-level stream teardown (e.g.
    /// `SCStream.stopCapture()`) without blocking a Swift-concurrency cooperative thread.
    ///
    /// Non-throwing by design (matches architecture.md). Stop failures are logged by the
    /// implementation and surface via the session-level `isolateAndContinue` path (#36).
    func stop() async
}

// MARK: - SampleSink

/// Receives `CMSampleBuffer`s from one or more `CaptureSource`s.
///
/// Implemented by `SampleRouter` in Application. The router fans out to the writers
/// and enforces backpressure / lossless audio semantics before forwarding.
///
/// Implementers are responsible for their own thread-safety. `receive(_:kind:)` is
/// called from GCD capture queues and must be safe to invoke without any actor isolation.
/// Lossless audio is enforced at this seam — implementations must never drop audio samples.
public protocol SampleSink: AnyObject, Sendable {
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
/// Implementers are responsible for their own thread-safety. All methods may be called
/// from GCD capture queues or the session control plane concurrently.
///
/// - Note on `isAlive`/`health` relationship: `isAlive == true` implies `health == .alive`.
///   `isAlive` is the **hot-path atomic subset** — polled wait-free from the sample thread
///   using acquire/release semantics (e.g. `Atomic<Bool>`).
///   `health` is the richer **control-plane signal** that may lag `isAlive` slightly; it
///   carries additional states (`.partial`, `.failed`) readable by the session coordinator.
///   Never use `health` on the sample path — poll `isAlive` there instead.
public protocol EncodingWriter: AnyObject, Sendable {
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
    /// Backed by an atomic load (acquire/release semantics), NOT a lock — see the
    /// type-level note on the `isAlive`/`health` relationship above.
    var isAlive: Bool { get }
}

// MARK: - DropReason

/// The reason a video frame was dropped by the `SampleRouter` backpressure mechanism.
///
/// Audio samples are never dropped (lossless audio guarantee). `DropReason` applies to
/// video tracks only.
///
/// - Note: Issue #39 (`DroppedFrameStats`) will consume this enum to build per-source
///   drop summaries that are included in the `recording.stop` event.
public enum DropReason: Sendable, Equatable, CaseIterable {
    /// The bounded video queue for this source was full; oldest frame evicted.
    case captureBound

    /// The `CVPixelBuffer` / `IOSurface` pool was exhausted; no buffer available to retain.
    case poolExhausted

    /// The hardware VideoToolbox encoder input queue was full; frame could not be submitted.
    case encoderBound

    /// Disk write throughput is saturated; the writer's input queue rejected the frame.
    case diskBound
}
