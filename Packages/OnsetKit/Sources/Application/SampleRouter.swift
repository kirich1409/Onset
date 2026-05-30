import CoreMedia
import Domain
import Synchronization

// MARK: - WriterBinding

/// Pairs an `EncodingWriter` with the video `SourceKind` it owns.
///
/// The screen-writer owns `.screen` video, the camera-writer owns `.camera` video.
/// Audio fans out to every binding's writer whose `isAlive` is `true`
/// — no binding-level filtering on audio.
///
/// # Usage
/// ```swift
/// let bindings: [WriterBinding] = [
///     WriterBinding(writer: screenWriter, videoSource: .screen),
///     WriterBinding(writer: cameraWriter, videoSource: .camera),
/// ]
/// let router = SampleRouter(writers: bindings)
/// ```
///
/// # no-test-required: pure data carrier (no logic)
public struct WriterBinding: Sendable {
    /// The encoding writer for this output file.
    public let writer: any EncodingWriter

    /// The video `SourceKind` whose `.video` track this writer owns.
    /// `.audio` is not a valid value here; audio routes to all writers.
    public let videoSource: SourceKind

    public init(writer: any EncodingWriter, videoSource: SourceKind) {
        self.writer = writer
        self.videoSource = videoSource
    }
}

// MARK: - SampleRouter

/// Routes `CMSampleBuffer`s from capture sources to their encoding writers.
///
/// Implemented by this type in Application (`Application/SampleRouter.swift`).
/// It is the sole concrete `SampleSink` on the hot capture path.
///
/// ## Routing rules
/// - **Video** (kind `.screen` or `.camera`): forwarded to the one writer whose
///   `WriterBinding.videoSource` matches.  If no binding matches the kind (e.g. no
///   camera writer was wired), the buffer is silently discarded — this is expected
///   when the user deselects a source before recording.
/// - **Audio** (kind `.audio`): fanned out to **every** writer in `writers` whose
///   `isAlive == true`.  The same `CMSampleBuffer` object is passed to each; callers
///   must retain it only for the duration of `receive(_:kind:)`.  Audio is lossless
///   at this seam — no sample is ever dropped by the router.
///
/// ## Hot-path constraints
/// `receive(_:kind:)` is called from GCD capture serial queues
/// (`com.app.capture.{screen,camera,audio}`). It is:
/// - `nonisolated` — no actor hop, no `await`
/// - lock-free — only `Atomic` loads/stores on the hot path
/// - allocation-free — no closures captured, no `.filter {}`, no dynamic dispatch
///   beyond the existing writer array walk
///
/// ## Per-source counters
/// `screenReceivedCount`, `cameraReceivedCount`, and `audioReceivedCount` count
/// `receive` calls per source kind — an ingress tally, incremented unconditionally on
/// every `receive` call regardless of whether the target writer is alive.  Real per-source
/// **drop** accounting (bounded queue, drop-oldest) is deferred to issue #39
/// (`DroppedFrameStats`); #35 introduces no drop path.  These counters are read on the
/// control plane after stop; `.relaxed` ordering is correct and cheapest.
///
/// ## Thread-safety
/// All stored state is either `let`-immutable (writers array, video-source writers) or
/// `Atomic` (counters). `Sendable` conformance is unchecked because `Atomic` is
/// `~Copyable` and the Swift 6 checker cannot verify `~Copyable` stored properties as
/// of this SDK; all state is nonetheless safe — atomics are lock-free and the writers
/// array is read-only after init.
public final class SampleRouter: SampleSink, @unchecked Sendable {

    // MARK: - Storage

    /// All writers in insertion order — used for audio fan-out.
    private let writers: [any EncodingWriter]

    /// The writer for `.screen` video, if one was provided.
    private let screenWriter: (any EncodingWriter)?

    /// The writer for `.camera` video, if one was provided.
    private let cameraWriter: (any EncodingWriter)?

    // MARK: - Per-source ingress counters

    /// Ingress count for `.screen` buffers.  Incremented on every `receive(.screen)`
    /// call; does NOT reflect whether the writer was alive.
    private let _screenReceivedCount = Atomic<UInt64>(0)

    /// Ingress count for `.camera` buffers.  Incremented on every `receive(.camera)`
    /// call; does NOT reflect whether the writer was alive.
    private let _cameraReceivedCount = Atomic<UInt64>(0)

    /// Ingress count for `.audio` buffers.  One increment per `receive(.audio)` call,
    /// not per fan-out writer.
    private let _audioReceivedCount = Atomic<UInt64>(0)

    // MARK: - Init

    /// Creates a `SampleRouter` wired to the given writer bindings.
    ///
    /// - Parameter writers: One binding per output file.  Typically two: one for
    ///   `.screen` and one for `.camera`.  The order determines the iteration order
    ///   for audio fan-out — stable, predictable, and allocation-free at call time.
    public init(writers: [WriterBinding]) {
        // Precompute O(1) video lookups from the (small, control-plane-time) bindings.
        self.writers = writers.map(\.writer)
        self.screenWriter = writers.first(where: { $0.videoSource == .screen })?.writer
        self.cameraWriter = writers.first(where: { $0.videoSource == .camera })?.writer
    }

    // MARK: - Public ingress counter accessors (control plane)

    /// Number of `.screen` `receive` calls since construction (ingress tally).
    /// Counts every call regardless of writer liveness.
    /// Read on the control plane after stop; `.relaxed` ordering is sufficient.
    public var screenReceivedCount: UInt64 {
        _screenReceivedCount.load(ordering: .relaxed)
    }

    /// Number of `.camera` `receive` calls since construction (ingress tally).
    /// Counts every call regardless of writer liveness.
    public var cameraReceivedCount: UInt64 {
        _cameraReceivedCount.load(ordering: .relaxed)
    }

    /// Number of `.audio` `receive` calls since construction (ingress tally,
    /// one per call — not per fan-out writer).
    public var audioReceivedCount: UInt64 {
        _audioReceivedCount.load(ordering: .relaxed)
    }

    // MARK: - SampleSink

    /// Routes `buf` to the appropriate writer(s) based on `kind`.
    ///
    /// Called from GCD capture serial queues; must be lock-free and allocation-free.
    /// See the type-level doc for routing semantics.
    public func receive(_ buf: CMSampleBuffer, kind: SourceKind) {
        switch kind {
        case .screen:
            if let writer = screenWriter, writer.isAlive {
                writer.append(buf, track: .video)
            }
            _screenReceivedCount.wrappingAdd(1, ordering: .relaxed)

        case .camera:
            if let writer = cameraWriter, writer.isAlive {
                writer.append(buf, track: .video)
            }
            _cameraReceivedCount.wrappingAdd(1, ordering: .relaxed)

        case .audio:
            // Audio is lossless at this seam — iterate in place, no allocation.
            for writer in writers where writer.isAlive {
                writer.append(buf, track: .audio)
            }
            _audioReceivedCount.wrappingAdd(1, ordering: .relaxed)
        }
    }
}
