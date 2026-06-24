import CoreMedia
import CoreVideo

// file_length is disabled: this file is the shared pipeline value-type vocabulary (HostTimeAnchor,
// VideoFrame, AudioSample, RecordingState, SourceEvent, …). Each type carries the non-obvious
// `InferIsolatedConformances` / `@MainActor`-isolation rationale that `code-policies.md` requires
// preserved; the manual nonisolated Equatable/Hashable witnesses cannot be split into sibling
// files without duplicating that documentation. swiftlint:disable file_length

// MARK: - HostTimeAnchor

/// The single shared timeline origin for one recording session.
///
/// T0 is captured once — by `RecordingSession` (#34) at the moment recording starts — then
/// passed to every source's `start(anchoredTo:)` and to `FileWriter.startSession`. Every
/// `ptsHostTime` carried on `VideoFrame` / `AudioSample` is expressed relative to this anchor.
///
/// In Wave 1, sources that run without a `RecordingSession` (e.g. unit tests, preview actors)
/// use `HostTimeAnchor.now()` as a standalone default until `RecordingSession` exists.
nonisolated struct HostTimeAnchor {
    /// The host-clock time at which recording started.
    ///
    /// All pipeline pts values are offsets from this origin: pts = sampleHostTime − anchorTime.
    /// CMTime arithmetic (`CMTimeSubtract`) is the correct operation when rebasing; no
    /// clock-conversion APIs are needed because both operands live on the same host clock.
    nonisolated let anchorTime: CMTime

    /// Captures the current host-clock time as a recording origin.
    ///
    /// Extracted into a `nonisolated static func` — not a `static let` — for two reasons:
    /// 1. Correctness: T0 must be captured at session-start time, not at static-init time.
    /// 2. Isolation safety: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    ///    `NonisolatedNonsendingByDefault`, a closure literal in a `nonisolated static let`
    ///    is still inferred `@MainActor`. A named function carries `nonisolated` unambiguously
    ///    through the type-checker (same pattern as `RecordingConfiguration.makeMVPDefault()`).
    nonisolated static func now() -> Self {
        // CMClockGetHostTimeClock() / CMClockGetTime() are safe under this toolchain —
        // the Swift importer exposes them without unsafe pointer indirection at the call site.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return Self(anchorTime: now)
    }
}

// MARK: - PipelineClock

/// A thin, stateless facade over the CoreMedia host-time clock.
///
/// Exposes exactly two operations needed by the pipeline:
/// - `currentHostTime`: the present moment as a `CMTime` on the host clock.
/// - `convert(hostTime:anchoredTo:)`: rebases an absolute host-time `CMTime` into the
///   anchored timeline (sampleTime = hostTime − anchor.anchorTime).
///
/// Why these specific APIs:
/// - The "host clock" is the mach-time clock returned by `CMClockGetHostTimeClock()`.
///   Sources stamp each sample's arrival time directly on this clock (SCStreamOutput /
///   AVCaptureVideoDataOutput both deliver host-time CMSampleBuffers).
/// - Rebasing onto a T0 anchor is single-timeline arithmetic (`CMTimeSubtract`), NOT a
///   clock conversion. `CMSyncConvertTime(_:from:to:)` is the correct tool when converting
///   between *different* clocks (e.g. a display-vsync clock onto the host clock) — that
///   operation belongs in the source ingest layer (#28/#29), not here.
/// - `CMTimebase` is a stateful object with a settable rate/time; using it here would
///   introduce mutable state in what must be a pure utility.
/// - `CMClockConvertHostTimeToSystemUnits` converts CMTime → raw mach UInt64 — wrong type
///   and wrong direction.
nonisolated enum PipelineClock {
    /// Returns the current host-clock time.
    ///
    /// `CMClockGetHostTimeClock()` and `CMClockGetTime()` are safe C functions — the Swift
    /// importer exposes them as ordinary Swift calls with no unsafe pointer indirection at
    /// the call site under this toolchain version. No `unsafe` wrapper is required.
    nonisolated static func currentHostTime() -> CMTime {
        // CMClockGetHostTimeClock() and CMClockGetTime() are safe in this SDK — no `unsafe`
        // wrapper required under SWIFT_STRICT_MEMORY_SAFETY = YES with the Xcode 26 toolchain.
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// Rebases an absolute host-time `CMTime` into the anchored recording timeline.
    ///
    /// `result = hostTime − anchor.t0`
    ///
    /// Both operands are host-clock times, so this is pure `CMTime` arithmetic —
    /// not a clock-domain conversion. The result is the media-pts value that encoders
    /// and writers use.
    ///
    /// - Parameters:
    ///   - hostTime: An absolute host-clock time (e.g. `ptsHostTime` from a raw sample).
    ///   - anchor: The session anchor whose `anchorTime` defines the timeline origin.
    /// - Returns: A `CMTime` representing the offset from T0. Will be negative if
    ///   `hostTime` precedes the anchor — callers should guard against that.
    nonisolated static func convert(hostTime: CMTime, anchoredTo anchor: HostTimeAnchor) -> CMTime {
        CMTimeSubtract(hostTime, anchor.anchorTime)
    }
}

// MARK: - VideoFrame

/// A single video frame traveling through the capture→encode pipeline.
///
/// ### Thread-safety and `@unchecked Sendable`
/// `CVPixelBuffer` is a reference type and not `Sendable`. The `@unchecked` annotation is
/// sound here because the pipeline enforces a strict read-only-after-ingest invariant:
/// the source allocates the buffer from its pool and writes pixels exactly once before
/// handing the frame downstream. Nothing in the encode or write path mutates the pixel
/// data; the buffer is released when the `VideoFrame` is deallocated. Crossing isolation
/// boundaries (source actor → encoder actor → writer actor) is therefore safe despite
/// the reference semantics.
///
/// ### Seam for VideoEncoder (#31)
/// `VideoEncoder.ingest(_ frame: VideoFrame)` receives this type directly. The
/// `pixelBuffer` is already encoder-compatible (biplanar 420v/420f, IOSurface-backed,
/// no per-frame format conversion). The `ptsHostTime` is already on the host clock —
/// no re-conversion in the encoder.
nonisolated struct VideoFrame: @unchecked Sendable {
    /// The pixel buffer delivered by the capture source.
    ///
    /// INVARIANT: read-only after ingest. No downstream component may call
    /// `CVPixelBufferLockBaseAddress` for write access or modify the IOSurface backing.
    ///
    /// `nonisolated` is not applied to this stored property: stored properties of
    /// `nonisolated struct` types already have nonisolated access by default; the keyword
    /// applies only to members of actor/`@MainActor` types that need to opt out of isolation.
    let pixelBuffer: CVPixelBuffer

    /// Presentation timestamp on the host clock at which the frame was captured.
    ///
    /// This is an ABSOLUTE host-clock time as delivered by the capture source
    /// (SCStreamOutput / AVCaptureVideoDataOutput). The source converts foreign-clock
    /// timestamps to host time at ingest using `CMSyncConvertTime`; nothing downstream
    /// re-converts. `FileWriter` calls `startSession(atSourceTime:)` with the first
    /// sample's `ptsHostTime` to set the timeline origin and appends all subsequent
    /// sample buffers raw — no per-sample `PipelineClock.convert()` is applied.
    let ptsHostTime: CMTime

    /// When `true`, this frame is a CFR hold-repeat: the source generated no new sample
    /// at this tick and the previous frame content should be re-used by the encoder.
    ///
    /// VideoEncoder (#31) uses this flag to distinguish a genuinely new frame (encode
    /// normally) from a hold: on hold-repeat the encoder may re-emit the previous
    /// compressed frame or synthesize a duplicate without re-encoding. The pixel buffer
    /// content is still valid (it holds the previous frame's data) to avoid a nil-buffer
    /// special case in the hot path.
    let isHoldRepeat: Bool
}

// MARK: - AudioSample

/// A single audio sample buffer traveling through the capture→mix pipeline.
///
/// ### Thread-safety and `@unchecked Sendable`
/// `CMSampleBuffer` is a reference type and not `Sendable`. The `@unchecked` annotation is
/// sound for the same reason as `VideoFrame`: the microphone source fills the buffer once
/// and never mutates it downstream. The pipeline treats it as immutable from the moment
/// the source hands it off.
///
/// ### Seam for mic fan-out (#33)
/// One `AudioSample` is consumed by both `FileWriter` instances (screen file + camera file)
/// concurrently. Because the buffer is immutable after ingest, sharing the same reference
/// across two writers is safe.
nonisolated struct AudioSample: @unchecked Sendable {
    /// The CMSampleBuffer containing PCM audio data from the microphone.
    ///
    /// Format: biplanar or interleaved PCM as delivered by AVCaptureAudioDataOutput.
    /// INVARIANT: read-only after ingest — never call `CMSampleBufferMakeDataReady` for
    /// write or modify the buffer data downstream.
    let sampleBuffer: CMSampleBuffer

    /// Presentation timestamp of the first audio sample on the host clock.
    ///
    /// Absolute host-clock time, already converted by the mic source at ingest.
    /// Same contract as `VideoFrame.ptsHostTime`: no downstream re-conversion.
    let ptsHostTime: CMTime
}

// MARK: - EncodedSample

/// The output of `VideoEncoder` (#31), ready to be appended to an `AVAssetWriter`.
///
/// ### Thread-safety and `@unchecked Sendable`
/// `CMSampleBuffer` is not `Sendable`. The `@unchecked` annotation is sound because the
/// encoder produces the buffer and immediately releases its reference after handing it
/// downstream; the writer consumes it and releases it after appending. No concurrent
/// mutation occurs.
///
/// ### Seam for FileWriter (#32)
/// `FileWriter.append(_ sample: EncodedSample)` receives this type. The `sampleBuffer`
/// is formatted for direct `AVAssetWriterInput.append(_:)` — no intermediate conversion.
nonisolated struct EncodedSample: @unchecked Sendable {
    /// The encoded CMSampleBuffer output from VTCompressionSession.
    ///
    /// Contains the compressed HEVC bitstream. INVARIANT: read-only after handoff.
    let sampleBuffer: CMSampleBuffer

    /// Presentation timestamp of this encoded frame on the host clock.
    ///
    /// Matches the `ptsHostTime` of the source `VideoFrame` that produced this sample.
    /// `FileWriter` (#34) calls `startSession(atSourceTime:)` with the first sample's
    /// `ptsHostTime` to set the timeline origin and appends all subsequent sample buffers
    /// raw — no per-sample `PipelineClock.convert()` is applied. Calling `convert()` AND
    /// `startSession` would double-subtract and push frames before the session origin.
    let ptsHostTime: CMTime

    /// Whether this encoded sample is an HEVC IDR/CRA key frame.
    ///
    /// `AVAssetWriterInput.append(_:)` requires that the first appended sample be a
    /// key frame; subsequent non-keyframes are delta frames. `FileWriter` uses this
    /// flag to gate the start-of-stream append and to record GOP boundaries for seek.
    let isKeyframe: Bool
}

// MARK: - DropReason

/// The pipeline stage responsible for a dropped frame or sample.
///
/// Maps to three `DropMonitor` counters (tracked by #35/#36/#100) — not one-to-one:
/// `.captureDrop` and `.captureBackpressureDrops` both fold into the single `captureDrops`
/// counter and do NOT drive the degraded-state window:
/// - `captureDrop`: counted at the source (SCStream / AVCapture delivery callback).
/// - `cfrNormalizationDrops`: counted by the CFR normalizer when duplicate frames are
///   emitted for hold-repeat but the downstream is already full.
/// - `captureBackpressureDrops`: counted when the capture→encoder `AsyncStream` buffer
///   overflows. Distinct from encoder/disk pressure — does NOT drive the degraded alert.
/// - `encoderBackpressureDrops`: counted when an `AsyncStream` buffer overflows because
///   the encoder or writer is not consuming fast enough.
/// - `encoderHoldDrops`: a SYNTHETIC catch-up hold frame (a repeat of the last real frame)
///   was dropped at the encoder gate during a post-stall/sleep catch-up batch. Losing a hold
///   loses no user content (the next hold or real frame fills the slot), so it must NEVER drive
///   the degraded-state window, the one-way latch, or the user-facing "dropped N frames" count —
///   only the per-source diagnostic breakdown (#200).
nonisolated enum DropReason: Equatable, Hashable {
    /// The capture hardware or SCStream dropped a frame before it reached the pipeline.
    ///
    /// SCStreamOutput delivers this via `SCStreamOutputType.screen` with a status flag;
    /// AVCaptureVideoDataOutputSampleBufferDelegate reports it via
    /// `captureOutput(_:didDrop:from:reason:)`.
    case captureDrop

    /// A CFR normalizer-generated hold-repeat frame was dropped.
    ///
    /// Occurs when the source tick interval fires but the downstream stream buffer is full.
    /// The normalizer still accounts for the tick so the pts sequence is contiguous.
    case cfrNormalizationDrops

    /// A frame or sample was dropped because the capture→encoder `AsyncStream` buffer overflowed.
    ///
    /// Distinct from `.encoderBackpressureDrops` (encoder-gate / writer pressure): capture
    /// overflow indicates the capture layer is producing faster than the encoder consumes,
    /// NOT that the encoder or disk is overloaded. Folds into the `captureDrops` counter in
    /// `DropMonitor` and does NOT drive the degraded-state sliding window or post-stop alert.
    case captureBackpressureDrops

    /// A frame or sample was dropped because the downstream `AsyncStream` buffer overflowed.
    ///
    /// The stream is configured with `.bufferingNewest(_:)` — overflow evicts the OLDEST
    /// buffered element. The source detects the drop via the `yield` return value
    /// (`.dropped(evictedElement)`) and emits one `DropEvent` per eviction.
    case encoderBackpressureDrops

    /// A SYNTHETIC catch-up hold frame was dropped at the `VideoEncoder` pending-frame gate.
    ///
    /// After a scheduler stall or system sleep, the CFR clock emits a synchronous catch-up batch
    /// of up to `fps` hold frames (repeats of the last real frame). The gate's `pendingFrameCount`
    /// proxy cannot drain mid-batch, so holds beyond `maxPendingFrames` are dropped. Unlike
    /// `.encoderBackpressureDrops`, a dropped hold loses no user content — the next hold/real frame
    /// fills the slot — so it must NOT feed the degraded-state window, the one-way latch, or the
    /// user-facing dropped-frames counter. It remains visible in the per-source breakdown (#200).
    case encoderHoldDrops
}

extension DropReason {
    /// Manual `nonisolated` `Equatable` witness for the conformance declared on the primary
    /// `nonisolated enum DropReason` definition.
    ///
    /// The conformance is declared ON THE TYPE (not in a bare `extension DropReason: Equatable`)
    /// so it is itself `nonisolated` under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `InferIsolatedConformances`. A separate-extension conformance would be inferred
    /// `@MainActor`, which compiles `==` but makes `!=` (the default `Equatable` extension that
    /// needs the *conformance*) unusable from `nonisolated` contexts — see issue #187.
    nonisolated static func == (lhs: DropReason, rhs: DropReason) -> Bool {
        switch (lhs, rhs) {
        case (.captureDrop, .captureDrop),
             (.cfrNormalizationDrops, .cfrNormalizationDrops),
             (.captureBackpressureDrops, .captureBackpressureDrops),
             (.encoderBackpressureDrops, .encoderBackpressureDrops),
             (.encoderHoldDrops, .encoderHoldDrops):
            true

        default:
            false
        }
    }
}

extension DropReason {
    /// Manual `nonisolated` `Hashable` witness for the conformance declared on the primary
    /// `nonisolated enum DropReason` definition.
    ///
    /// Swift auto-synthesises `Hashable` for enums with no associated values, but under
    /// `InferIsolatedConformances` the synthesised `hash(into:)` witness is inferred
    /// `@MainActor`. An explicit manual `nonisolated` witness overrides the synthesised form.
    /// (`DropReason` needs `Hashable` because a `Sendable` enum may be used as a `Dictionary`
    /// key in `DropMonitor`'s counter table.)
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .captureDrop:
            hasher.combine(0)

        case .cfrNormalizationDrops:
            hasher.combine(1)

        case .captureBackpressureDrops:
            // Ordinal tag for the third enum case; 3 is not in no_magic_numbers' exempt list.
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(3)

        case .encoderBackpressureDrops:
            // Ordinal tag for the fourth enum case; 4 is not in no_magic_numbers' exempt list.
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(4)

        case .encoderHoldDrops:
            // Ordinal tag for the fifth enum case; 5 is not in no_magic_numbers' exempt list.
            // (Ordinal 2 is a historical gap in this switch — kept stable; 5 avoids any collision.)
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(5)
        }
    }
}

// MARK: - DropCause

/// The dominant pipeline stage that drove backpressure-degradation during a session.
///
/// Reported in the post-stop `DropHealthSnapshot` so the UI can surface the most actionable
/// signal to the user. Covers only the **backpressure** path — `captureDrop` and
/// `cfrNormalizationDrops` never trigger degraded state and therefore never produce a
/// non-`.notDegraded` cause.
///
/// Tie-break order when multiple stages accumulated backpressure drops:
///   writer > encode > captureScreen > captureCameraVideo > captureCameraAudio
/// The first matching non-zero bucket wins. The order is deterministic and documented so
/// tests can rely on it.
nonisolated enum DropCause: Equatable, Hashable {
    /// The session was never degraded (latch `sessionEverDegraded == false`).
    ///
    /// By invariant, `snapshot().dominantCause == .notDegraded` iff `sessionEverDegraded == false`.
    /// Named `notDegraded` rather than `none` to avoid ambiguity with `Optional<T>.none`,
    /// which the Swift compiler can conflate in type-inference contexts.
    case notDegraded
    /// `ScreenSource`→encoder `AsyncStream` buffer was the dominant backpressure site.
    case captureScreen
    /// `CameraSource` video→encoder `AsyncStream` buffer was the dominant backpressure site.
    case captureCameraVideo
    /// `CameraSource` audio→encoder `AsyncStream` buffer was the dominant backpressure site.
    case captureCameraAudio
    /// `VideoEncoder` pending-frame gate was the dominant backpressure site.
    case encode
    /// `FileWriter` input backpressure was the dominant site.
    case writer
}

/// Under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + InferIsolatedConformances, synthesised
/// Equatable and Hashable witnesses are inferred @MainActor. Manual nonisolated witnesses match
/// the pattern used by DropReason and DropSource so DropCause is usable from nonisolated code.
extension DropCause {
    /// Manual `nonisolated` implementation (mirrors `DropReason`).
    nonisolated static func == (lhs: DropCause, rhs: DropCause) -> Bool {
        switch (lhs, rhs) {
        case (.notDegraded, .notDegraded),
             (.captureScreen, .captureScreen),
             (.captureCameraVideo, .captureCameraVideo),
             (.captureCameraAudio, .captureCameraAudio),
             (.encode, .encode),
             (.writer, .writer):
            true

        default:
            false
        }
    }
}

extension DropCause {
    /// Manual `nonisolated` implementation.
    ///
    /// Swift auto-synthesises `Hashable` for enums with no associated values. Under
    /// `InferIsolatedConformances`, the synthesised `hash(into:)` witness is inferred
    /// `@MainActor`, making `DropCause` unusable from `nonisolated` contexts. Providing
    /// an explicit manual witness with `nonisolated` overrides the synthesised form
    /// (mirrors the identical pattern on `DropReason`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .notDegraded:
            hasher.combine(0)

        case .captureScreen:
            hasher.combine(1)

        case .captureCameraVideo:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(2)

        case .captureCameraAudio:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(3)

        case .encode:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(4)

        case .writer:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(5)
        }
    }
}

// MARK: - DropSource

/// The pipeline stage that detected a frame or sample drop.
///
/// Carried on every `DropEvent` so `DropMonitor` can accumulate a per-source breakdown
/// and emit a single diagnostic summary line at session stop. This is a DIAGNOSTIC
/// dimension only — it does NOT alter the existing per-`DropReason` counter accounting
/// (`DropCounters`) or the UI-facing `RecordingState` logic.
nonisolated enum DropSource: Equatable, Hashable {
    /// SCStream video frame overflowed the capture → encoder `AsyncStream` buffer.
    case captureScreen

    /// AVCapture camera video frame overflowed the capture → encoder `AsyncStream` buffer.
    case captureCameraVideo

    /// AVCapture microphone audio sample overflowed the capture → encoder `AsyncStream` buffer.
    case captureCameraAudio

    /// VideoEncoder pending-frame gate dropped a frame before VT compression.
    case encode

    /// FileWriter input was not ready (writer/disk backpressure); compressed sample dropped.
    case writer
}

/// Under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + InferIsolatedConformances, synthesised
/// Equatable and Hashable witnesses are inferred @MainActor. Manual nonisolated witnesses match
/// the pattern used by DropReason and DropCounters so DropSource is usable from nonisolated code.
extension DropSource {
    /// Manual `nonisolated` implementation (mirrors `DropReason`).
    nonisolated static func == (lhs: DropSource, rhs: DropSource) -> Bool {
        switch (lhs, rhs) {
        case (.captureScreen, .captureScreen),
             (.captureCameraVideo, .captureCameraVideo),
             (.captureCameraAudio, .captureCameraAudio),
             (.encode, .encode),
             (.writer, .writer):
            true

        default:
            false
        }
    }
}

extension DropSource {
    /// Manual `nonisolated` implementation.
    ///
    /// Swift auto-synthesises `Hashable` for enums with no associated values. Under
    /// `InferIsolatedConformances`, the synthesised `hash(into:)` witness is inferred
    /// `@MainActor`, making `DropSource` unusable from `nonisolated` contexts. Providing
    /// an explicit manual witness with `nonisolated` overrides the synthesised form
    /// (mirrors the identical pattern on `DropReason`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .captureScreen:
            hasher.combine(0)

        case .captureCameraVideo:
            hasher.combine(1)

        case .captureCameraAudio:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(2)

        case .encode:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(3)

        case .writer:
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(4)
        }
    }
}

// MARK: - DropEvent

/// An event emitted by a capture source when a frame or sample was dropped.
///
/// Sources deliver these on their `drops: AsyncStream<DropEvent>` channel so that
/// `DropMonitor` (#35/#36) can maintain per-reason counters and surface the HUD display.
///
/// The count field enables batch reporting: if the source detects N drops in a single
/// callback (e.g. the async-stream buffer was full for N consecutive ticks), it may
/// emit one `DropEvent` with `count > 1` instead of N individual events.
nonisolated struct DropEvent: Equatable {
    /// The pipeline stage where the drop occurred.
    nonisolated let reason: DropReason

    /// The pipeline stage that detected the drop. Used for the diagnostic per-source
    /// breakdown logged at session stop; does not affect counter accounting.
    nonisolated let source: DropSource

    /// Number of frames or samples dropped in this event. Always ≥ 1.
    nonisolated let count: Int

    /// Host-clock time at which the drop was detected.
    nonisolated let detectedAt: CMTime
}

// MARK: - RecordingState

/// The pipeline's backpressure-health state, surfaced by `DropMonitor` (#35) to the UI (#37).
///
/// Policy (user decision — "Degraded = Live with recovery"): the session is `.degraded` while the
/// count of `encoderBackpressureDrops` within a sliding window exceeds a threshold, and recovers
/// to `.normal` once the window clears. Only encoder-backpressure drops drive this state; capture
/// and CFR-normalization drops are tracked as cumulative counters but never change `RecordingState`.
///
/// `Equatable` / `Hashable` are declared ON THE PRIMARY definition (not a bare extension) so the
/// conformances themselves are `nonisolated` — required so `RecordingState` is comparable from
/// inside `actor DropMonitor`. A bare `extension RecordingState: Equatable` would leave the
/// conformance `@MainActor`-isolated under `InferIsolatedConformances` even with a nonisolated
/// witness, and `==` would then be unusable in actor-isolated code (same pattern as
/// `VideoEncoder.State`).
nonisolated enum RecordingState: Equatable, Hashable {
    /// Backpressure is within budget — the encoder/writer is keeping up.
    case normal

    /// Backpressure drops within the sliding window exceeded the threshold. Recording continues
    /// (Live); the monitor recovers to `.normal` automatically when the window clears.
    case degraded
}

extension RecordingState {
    /// Manual `nonisolated` implementation.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are inferred
    /// `@MainActor` (`InferIsolatedConformances`). All value-type enums in this project override
    /// this via manual nonisolated witnesses — see `DropReason`.
    nonisolated static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.normal, .normal),
             (.degraded, .degraded):
            true

        default:
            false
        }
    }
}

extension RecordingState {
    /// Manual `nonisolated` implementation.
    ///
    /// A payload-free enum gets an IMPLICIT `Hashable` synthesis even without an explicit
    /// declaration; under `InferIsolatedConformances` that synthesised `hash(into:)` witness is
    /// inferred `@MainActor`, which makes `RecordingState` cross into main-actor code from
    /// `nonisolated` contexts. An explicit manual witness overrides it (same pattern as `DropReason`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .normal:
            hasher.combine(0)

        case .degraded:
            hasher.combine(1)
        }
    }
}

// MARK: - SourceEvent

/// Out-of-band lifecycle events emitted by a capture source.
///
/// Delivered on `VideoFrameSource.events: AsyncStream<SourceEvent>`. These are low-volume
/// signals about the source's health, not frame-level data. `RecordingSession` (#34)
/// observes this stream to decide whether to pause, stop, or degrade gracefully.
nonisolated enum SourceEvent: Equatable {
    /// The display being recorded was physically disconnected.
    ///
    /// Emitted by `ScreenSource` (#28) when SCKit reports the display is no longer
    /// available (SCStreamDelegate `stream(_:didStopWithError:)` with a hotplug reason,
    /// or SCShareableContent returning an empty display list). `RecordingSession` should
    /// stop the session on this event; partial output is still valid.
    case displayDisconnected

    /// The camera device was physically disconnected or became unavailable.
    ///
    /// Emitted by `CameraSource` (#29) when AVCaptureDevice posts
    /// `.AVCaptureDeviceWasDisconnected` or the device becomes unavailable mid-session.
    /// Also reused for `AVCaptureSession` runtime errors and interruptions (session fault
    /// path). When issue #164 (diagnostics) is implemented, this case may need an
    /// associated reason value to distinguish a physical disconnect from a session fault.
    case cameraDisconnected

    /// The source encountered a non-fatal error that required an internal restart.
    ///
    /// The source will continue delivering frames; the event carries the reason for
    /// diagnostic logging. If the source cannot recover, it will finish its streams instead.
    case sourceInterrupted(reason: String)
}

extension SourceEvent {
    nonisolated static func == (lhs: SourceEvent, rhs: SourceEvent) -> Bool {
        switch (lhs, rhs) {
        case (.displayDisconnected, .displayDisconnected),
             (.cameraDisconnected, .cameraDisconnected):
            true

        case let (.sourceInterrupted(lhsReason), .sourceInterrupted(rhsReason)):
            lhsReason == rhsReason

        default:
            false
        }
    }
}

// MARK: - RecordingRevocation

/// A revocation notification carried on `RecordingSession.sourceRevocationStream`.
///
/// `RecordingSession` already FINALISES the affected pipeline on a `.displayDisconnected` /
/// `.cameraDisconnected` `SourceEvent` (Epic 3) or on a hard writer fault (#197). This stream is the
/// *UI seam* layered on top of that behaviour: after a pipeline is finalised, the session yields a
/// `RecordingRevocation` so the `RecordingCoordinator` can update the per-source liveness the
/// recording window reads — and, when the last video pipeline is gone, learn it must end the session.
///
/// **Single-consumer.** Exactly ONE subscriber (the `RecordingCoordinator`) may iterate the stream —
/// same contract as `recordingStateStream`. `AsyncStream` splits elements across iterators rather
/// than duplicating them, so a second consumer would starve the first.
nonisolated enum RecordingRevocation: Equatable {
    /// One video source was revoked mid-recording and its pipeline finalised (AC-12). The other
    /// pipeline (if any) keeps recording. `.camera` additionally implies the microphone ended (the
    /// mic rides the camera AVCaptureSession), so the coordinator marks the mic revoked too.
    case sourceRevoked(RecordingPipelineKind)

    /// One pipeline's `FileWriter` hard-faulted mid-recording (#197). The pipeline is stopped and
    /// finalised as `.failed`; the other pipeline continues. The coordinator flips the faulted
    /// source's liveness to `false` so the recording window shows it stopped immediately.
    /// `.camera` additionally implies the microphone ended (same AVCaptureSession dependency as
    /// `.sourceRevoked(.camera)`). Visually reuses the same "stopped" indicator as AC-12.
    case writerFailed(RecordingPipelineKind)

    /// The LAST remaining video pipeline was just finalised — no video source is left. The
    /// coordinator must stop + finalise the session and surface the result (there is nothing left to
    /// record). Yielded immediately after the `.sourceRevoked` / `.writerFailed` for the final
    /// pipeline.
    case allVideoSourcesLost
}

extension RecordingRevocation {
    /// Manual `nonisolated` implementation.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are inferred
    /// `@MainActor` (`InferIsolatedConformances`). Declaring `: Equatable` on the enum itself keeps
    /// the conformance non-isolated; the manual nonisolated witness here overrides the synthesised
    /// one so `==` is callable from actor-isolated code and from nonisolated test contexts
    /// (same pattern as `RecordingState` / `SourceEvent` / `DropReason`).
    nonisolated static func == (lhs: RecordingRevocation, rhs: RecordingRevocation) -> Bool {
        switch (lhs, rhs) {
        case let (.sourceRevoked(lhsKind), .sourceRevoked(rhsKind)):
            lhsKind == rhsKind

        case let (.writerFailed(lhsKind), .writerFailed(rhsKind)):
            lhsKind == rhsKind

        case (.allVideoSourcesLost, .allVideoSourcesLost):
            true

        default:
            false
        }
    }
}

// MARK: - CaptureRole

/// Which lifecycle a `CameraSource` serves: full recording, or a lightweight preview.
///
/// `rawValue` is the wire-format token emitted in the `role=` field of every capture
/// telemetry line. Keep these stable — log analysis depends on the exact strings.
///
/// Role-conditional behavior lives in two guard sites: `CameraSource.start()` (telemetry task)
/// and `CameraSource+SessionSetup.attachOutputs(to:shims:)` (data outputs). Add a third
/// gate in both places if a new role-specific behavior is needed.
nonisolated enum CaptureRole: String, Equatable {
    /// Live preview: session runs for the preview layer only; no data outputs, no telemetry task.
    case preview
    /// Full recording: video data output attached, frames yielded, telemetry flushed.
    case record
}

extension CaptureRole {
    /// Manual `nonisolated` implementation.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are inferred
    /// `@MainActor` (`InferIsolatedConformances`). Providing an explicit manual witness with
    /// `nonisolated` overrides the synthesised form so `==` is callable from actor-isolated code
    /// and from nonisolated contexts (same pattern as `RecordingState` / `DropReason`).
    nonisolated static func == (lhs: CaptureRole, rhs: CaptureRole) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

// MARK: - CriticalIncidentScope

/// Which tracks a camera-loss incident affected, distinguishing the two `cameraLost` outcomes.
///
/// Drives the severity tier (see `CriticalIncident.severity`): camera-only loss stops the whole
/// session (`hard`), whereas a loss while the screen keeps recording is recoverable (`soft`).
/// Spec "Критерии «пожара» §1".
///
/// `Equatable` / `Hashable` declared on the primary definition with manual `nonisolated` witnesses
/// (same reasoning as `RecordingState`) so the conformances are usable off the main actor — required
/// because `CriticalIncident.hash(into:)` calls `hasher.combine(scope)` from a nonisolated context.
nonisolated enum CriticalIncidentScope: Equatable, Hashable {
    /// The camera was the only video source; its loss stopped the session entirely (`hard`).
    case cameraOnly

    /// The camera was lost while the screen continued recording normally (`soft`).
    case cameraAndScreen
}

extension CriticalIncidentScope {
    /// Manual `nonisolated` `==` witness (overrides the `@MainActor` synthesis under
    /// `InferIsolatedConformances` — same pattern as `RecordingState`).
    nonisolated static func == (lhs: CriticalIncidentScope, rhs: CriticalIncidentScope) -> Bool {
        switch (lhs, rhs) {
        case (.cameraOnly, .cameraOnly),
             (.cameraAndScreen, .cameraAndScreen):
            true

        default:
            false
        }
    }
}

extension CriticalIncidentScope {
    /// Manual `nonisolated` `hash(into:)` witness (overrides the `@MainActor`-inferred implicit
    /// synthesis for payload-free enums — same pattern as `RecordingState`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .cameraOnly:
            hasher.combine(0)

        case .cameraAndScreen:
            hasher.combine(1)
        }
    }
}

// MARK: - CriticalSeverity

/// The two-tier severity model that drives ALL critical-signal behavior (indicator, notification
/// level, latch, dedupe). Spec "Severity-модель".
///
/// `hard > soft`: a `hard` incident always overrides a previously shown `soft` one. NO `Comparable`
/// conformance is provided in this phase — ordering logic lives in later phases.
///
/// `Equatable` / `Hashable` declared on the primary definition with manual `nonisolated` witnesses
/// (same reasoning as `RecordingState`).
nonisolated enum CriticalSeverity: Equatable, Hashable {
    /// Recoverable problem; the primary (screen) track is intact. Notification level `active`.
    case soft

    /// Serious problem: recording stopped or sustained loss. Notification level `timeSensitive`.
    case hard
}

extension CriticalSeverity {
    /// Manual `nonisolated` `==` witness (same pattern as `RecordingState`).
    nonisolated static func == (lhs: CriticalSeverity, rhs: CriticalSeverity) -> Bool {
        switch (lhs, rhs) {
        case (.soft, .soft),
             (.hard, .hard):
            true

        default:
            false
        }
    }
}

extension CriticalSeverity {
    /// Manual `nonisolated` `hash(into:)` witness (same pattern as `RecordingState`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .soft:
            hasher.combine(0)

        case .hard:
            hasher.combine(1)
        }
    }
}

// MARK: - CriticalIncident

/// A discrete "fire" detected during recording: a problem serious enough to warrant an active signal
/// to the user (menu-bar indicator + notification), beyond the disk-only path for minor drops.
/// Spec "Критерии «пожара»".
///
/// HAS an associated value (`cameraLost(scope:)`), so it needs BOTH a manual `nonisolated static func ==`
/// and a manual `nonisolated func hash(into:)` — same as `SourceEvent` — to stay usable off the main
/// actor under `InferIsolatedConformances`. The `hash(into:)` threads `scope` through for the
/// associated-value case.
nonisolated enum CriticalIncident: Equatable, Hashable {
    /// The camera was lost mid-session. `scope` distinguishes a session-stopping camera-only loss
    /// (`hard`) from a loss while the screen kept recording (`soft`). Spec §1.
    case cameraLost(scope: CriticalIncidentScope)

    /// Degradation held continuously past the sustain threshold, or post-stop drop intensity exceeded
    /// the normalized rate floor. Always `hard`. Spec §2.
    case sustainedDrops

    /// Delivered camera fps collapsed below a fraction of its measured baseline, corroborated by a
    /// drop/overflow rate or an excessive frame gap. Always `hard`. Spec §3.
    case fpsCollapse

    /// The severity tier of this incident, per the spec Severity-модель table.
    ///
    /// `.cameraLost(.cameraAndScreen)` is `soft` (screen track intact); everything else — camera-only
    /// loss, sustained drops, fps collapse — is `hard`.
    nonisolated var severity: CriticalSeverity {
        switch self {
        case .cameraLost(.cameraAndScreen):
            .soft

        case .cameraLost(.cameraOnly), .sustainedDrops, .fpsCollapse:
            .hard
        }
    }
}

extension CriticalIncident {
    /// Manual `nonisolated` `==` witness (associated-value enum — same pattern as `SourceEvent`).
    nonisolated static func == (lhs: CriticalIncident, rhs: CriticalIncident) -> Bool {
        switch (lhs, rhs) {
        case let (.cameraLost(lhsScope), .cameraLost(rhsScope)):
            lhsScope == rhsScope

        case (.sustainedDrops, .sustainedDrops),
             (.fpsCollapse, .fpsCollapse):
            true

        default:
            false
        }
    }
}

extension CriticalIncident {
    /// Manual `nonisolated` `hash(into:)` witness.
    ///
    /// Combines a per-case discriminant; for `.cameraLost` it also combines `scope` so two incidents
    /// that differ only by scope hash differently (and stay consistent with `==`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case let .cameraLost(scope):
            hasher.combine(0)
            hasher.combine(scope)

        case .sustainedDrops:
            hasher.combine(1)

        case .fpsCollapse:
            // Ordinal tag for the third enum case; 2 is not in no_magic_numbers' exempt list.
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(2)
        }
    }
}
