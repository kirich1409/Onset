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
/// `screenRoutedCount`, `cameraRoutedCount`, and `audioRoutedCount` count successful
/// `receive` calls per source.  They are read on the control plane (coordinator) after
/// stop; `.relaxed` ordering is correct and cheapest.  Real per-source drop accounting
/// (bounded queue, drop-oldest) lands in issue #39 (`DroppedFrameStats`).
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

    // MARK: - Per-source routed-sample counters

    /// Number of `.screen` video `receive` calls forwarded to the screen writer.
    private let _screenRoutedCount = Atomic<UInt64>(0)

    /// Number of `.camera` video `receive` calls forwarded to the camera writer.
    private let _cameraRoutedCount = Atomic<UInt64>(0)

    /// Number of `.audio` `receive` calls fanned out (one increment per call,
    /// regardless of how many writers are alive).
    private let _audioRoutedCount = Atomic<UInt64>(0)

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

    // MARK: - Public counter accessors (control plane)

    /// Number of `.screen` video buffers routed since construction.
    /// Read on the control plane after stop; `.relaxed` ordering is sufficient.
    public var screenRoutedCount: UInt64 {
        _screenRoutedCount.load(ordering: .relaxed)
    }

    /// Number of `.camera` video buffers routed since construction.
    public var cameraRoutedCount: UInt64 {
        _cameraRoutedCount.load(ordering: .relaxed)
    }

    /// Number of `.audio` buffers routed since construction (one per `receive` call,
    /// not per fan-out writer).
    public var audioRoutedCount: UInt64 {
        _audioRoutedCount.load(ordering: .relaxed)
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
            _screenRoutedCount.wrappingAdd(1, ordering: .relaxed)

        case .camera:
            if let writer = cameraWriter, writer.isAlive {
                writer.append(buf, track: .video)
            }
            _cameraRoutedCount.wrappingAdd(1, ordering: .relaxed)

        case .audio:
            // Audio is lossless at this seam — iterate in place, no allocation.
            for writer in writers where writer.isAlive {
                writer.append(buf, track: .audio)
            }
            _audioRoutedCount.wrappingAdd(1, ordering: .relaxed)
        }
    }
}
