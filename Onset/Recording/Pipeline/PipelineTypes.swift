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
/// Maps 1-to-1 with the three DropMonitor counters tracked by #35/#36:
/// - `captureDrop`: counted at the source (SCStream / AVCapture delivery callback).
/// - `cfrNormalizationDrops`: counted by the CFR normalizer when duplicate frames are
///   emitted for hold-repeat but the downstream is already full.
/// - `encoderBackpressureDrops`: counted when an `AsyncStream` buffer overflows because
///   the encoder or writer is not consuming fast enough.
nonisolated enum DropReason {
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

    /// A frame or sample was dropped because the downstream `AsyncStream` buffer overflowed.
    ///
    /// The stream is configured with `.bufferingNewest(_:)` — overflow evicts the OLDEST
    /// buffered element. The source detects the drop via the `yield` return value
    /// (`.dropped(evictedElement)`) and emits one `DropEvent` per eviction.
    case encoderBackpressureDrops
}

extension DropReason: Equatable {
    /// Manual `nonisolated` implementation.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are
    /// inferred as `@MainActor` (`InferIsolatedConformances`). All value-type enums in
    /// this project override this via manual nonisolated extensions — see `Container`.
    nonisolated static func == (lhs: DropReason, rhs: DropReason) -> Bool {
        switch (lhs, rhs) {
        case (.captureDrop, .captureDrop),
             (.cfrNormalizationDrops, .cfrNormalizationDrops),
             (.encoderBackpressureDrops, .encoderBackpressureDrops):
            true

        default:
            false
        }
    }
}

extension DropReason: Hashable {
    /// Manual `nonisolated` implementation.
    ///
    /// Swift auto-synthesises `Hashable` for enums with no associated values. Under
    /// `InferIsolatedConformances`, the synthesised `hash(into:)` witness is inferred
    /// `@MainActor`, making `DropReason` unusable from `nonisolated` contexts. Providing
    /// an explicit manual witness with `nonisolated` overrides the synthesised form.
    /// (Same pattern documented on `BitrateKey` in `RecordingConfiguration.swift`, but
    /// for `DropReason` the `Hashable` conformance is required as a `Sendable` enum may
    /// be used as a `Dictionary` key in `DropMonitor`'s counter table.)
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .captureDrop:
            hasher.combine(0)

        case .cfrNormalizationDrops:
            hasher.combine(1)

        case .encoderBackpressureDrops:
            // Ordinal tag for the third enum case; 2 is not in no_magic_numbers' exempt list.
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(2)
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
nonisolated struct DropEvent {
    /// The pipeline stage where the drop occurred.
    nonisolated let reason: DropReason

    /// Number of frames or samples dropped in this event. Always ≥ 1.
    nonisolated let count: Int

    /// Host-clock time at which the drop was detected.
    nonisolated let detectedAt: CMTime
}

extension DropEvent: Equatable {}

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
nonisolated enum SourceEvent {
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
    case cameraDisconnected

    /// The source encountered a non-fatal error that required an internal restart.
    ///
    /// The source will continue delivering frames; the event carries the reason for
    /// diagnostic logging. If the source cannot recover, it will finish its streams instead.
    case sourceInterrupted(reason: String)
}

extension SourceEvent: Equatable {
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

/// A graceful-revocation notification carried on `RecordingSession.sourceRevocationStream` (AC-12 UI).
///
/// `RecordingSession` already FINALISES the affected pipeline on a `.displayDisconnected` /
/// `.cameraDisconnected` `SourceEvent` (Epic 3). This stream is the *UI seam* layered on top of that
/// behaviour: after a pipeline is finalised, the session yields a `RecordingRevocation` so the
/// `RecordingCoordinator` can update the per-source liveness the recording window reads — and, when
/// the last video pipeline is gone, learn it must end the whole session.
///
/// **Single-consumer.** Exactly ONE subscriber (the `RecordingCoordinator`) may iterate the stream —
/// same contract as `recordingStateStream`. `AsyncStream` splits elements across iterators rather
/// than duplicating them, so a second consumer would starve the first.
nonisolated enum RecordingRevocation: Equatable {
    /// One video source was revoked mid-recording and its pipeline finalised (AC-12). The other
    /// pipeline (if any) keeps recording. `.camera` additionally implies the microphone ended (the
    /// mic rides the camera AVCaptureSession), so the coordinator marks the mic revoked too.
    case sourceRevoked(RecordingPipelineKind)

    /// The LAST remaining video pipeline was just finalised — no video source is left. The
    /// coordinator must stop + finalise the session and surface the result (there is nothing left to
    /// record). Yielded immediately after the `.sourceRevoked` for the final pipeline.
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
