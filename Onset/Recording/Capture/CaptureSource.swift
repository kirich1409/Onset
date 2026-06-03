import CoreMedia

// MARK: - VideoFrameSource

/// Contract for a video capture source delivering frames into the encode pipeline.
///
/// Implemented by `actor ScreenSource` (#28) and `actor CameraSource` (#29).
///
/// ### Protocol shape and actor conformance
/// The three stream properties (`frames`, `drops`, `events`) are `nonisolated var`s so that
/// downstream consumers (encoder, writer, monitor) can subscribe without an `await`-hop
/// into the actor's isolation domain on the hot path. Conforming actors satisfy this by
/// storing the `AsyncStream`s as `let` constants in their `init` — the continuations are
/// held by the actor and driven from its isolated methods, but the *stream* itself is
/// accessible nonisolated.
///
/// The `async` requirements (`start`, `stop`) are ordinary actor-isolated methods; the
/// toolchain accepts `async` protocol requirements witnessed by actor-isolated methods
/// because actor isolation implies `async` at the call site.
///
/// ### Bounded buffers
/// Streams MUST be created with a bounded buffering policy:
/// ```swift
/// AsyncStream(VideoFrame.self, bufferingPolicy: .bufferingNewest(queueDepth))
/// ```
/// where `queueDepth` is typically 8–16 frames. On overflow, `.bufferingNewest` **evicts
/// the oldest** buffered element. The source detects overflow via the `yield` return value:
/// ```swift
/// if case .dropped = continuation.yield(frame) {
///     // emit DropEvent(.encoderBackpressureDrops, count: 1, detectedAt: ...)
/// }
/// ```
/// This is the backpressure signal that feeds `DropMonitor` (#35/#36) counters.
///
/// ### Host-time contract
/// Every `VideoFrame.ptsHostTime` MUST be an absolute host-clock time. The source converts
/// foreign-clock timestamps (display vsync, capture device clock) to host time at ingest
/// using `CMSyncConvertTime(_:from:to:)`. Nothing downstream re-converts.
///
/// `start(anchoredTo:)` is the T0 seam (#34): the session anchor is passed at start time.
/// Wave-1 sources may use `HostTimeAnchor.now()` as a standalone default until
/// `RecordingSession` exists.
nonisolated protocol VideoFrameSource: Sendable {
    /// The stream of captured video frames.
    ///
    /// Bounded with `.bufferingNewest(n)`. Overflow evicts the oldest element; the source
    /// emits a corresponding `DropEvent(.encoderBackpressureDrops)` on `drops`.
    ///
    /// The stream finishes when `stop()` is called and all in-flight frames are flushed.
    nonisolated var frames: AsyncStream<VideoFrame> { get }

    /// Out-of-band lifecycle events from the source (display disconnect, interruption, etc.).
    ///
    /// Low-volume. The stream finishes when `stop()` completes.
    nonisolated var events: AsyncStream<SourceEvent> { get }

    /// Drop events emitted by this source.
    ///
    /// Delivers one `DropEvent` per overflow or capture-layer drop. `DropMonitor` (#35)
    /// consumes this stream to maintain per-reason counters for the HUD display.
    ///
    /// The stream finishes when `stop()` completes.
    nonisolated var drops: AsyncStream<DropEvent> { get }

    /// Starts the capture source, anchored to the given recording timeline origin.
    ///
    /// The source begins delivering frames on `frames` after this call returns. The
    /// `anchor.anchorTime` value is stored by the source and used in `PipelineClock.convert`
    /// when producing anchored pts values for the writer layer.
    ///
    /// - Parameter anchor: The shared T0 for this recording session.
    /// - Throws: `RecordingError.captureSetupFailed` if the underlying capture session
    ///   cannot be started (permissions revoked, hardware unavailable, etc.).
    func start(anchoredTo anchor: HostTimeAnchor) async throws

    /// Stops the capture source and finishes all three streams.
    ///
    /// After this call, `frames`, `events`, and `drops` will deliver any remaining
    /// buffered elements and then terminate. Calling `stop()` on an already-stopped
    /// source is a no-op.
    func stop() async
}

// MARK: - AudioSampleSource

/// Contract for an audio capture source delivering samples into the mix pipeline.
///
/// Implemented by the microphone source in #33 (mic fan-out). Same actor-conformance
/// and bounded-buffer rules as `VideoFrameSource` — see its protocol doc for the rationale.
///
/// ### Host-time contract
/// Every `AudioSample.ptsHostTime` MUST be an absolute host-clock time. The source
/// converts the AVCaptureAudioDataOutput presentation timestamp to host time at ingest.
/// Nothing downstream re-converts.
nonisolated protocol AudioSampleSource: Sendable {
    /// The stream of captured audio sample buffers.
    ///
    /// Bounded with `.bufferingNewest(n)`. One `AudioSample` fans out to both file writers
    /// concurrently (#33); the buffer content is immutable after ingest.
    nonisolated var audioSamples: AsyncStream<AudioSample> { get }

    /// Drop events emitted by this source.
    ///
    /// Same semantics as `VideoFrameSource.drops`. Consumed by `DropMonitor` (#36).
    nonisolated var drops: AsyncStream<DropEvent> { get }

    /// Starts the audio capture source.
    ///
    /// - Parameter anchor: The shared T0 for this recording session.
    /// - Throws: `RecordingError.captureSetupFailed` if the microphone cannot be started.
    func start(anchoredTo anchor: HostTimeAnchor) async throws

    /// Stops the audio capture source and finishes all streams.
    func stop() async
}
