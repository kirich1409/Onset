// VideoEncoder.swift
// Onset
//
// U3 of #31 — the impure encoder actor: a single hardware HEVC `VTCompressionSession`
// per stream (screen / camera), CFR hold-frame normalisation, anchored-PTS snapping,
// backpressure gating, and a zero-copy IOSurface path.
//
// Layering: U1 `VTEncoderSettings` (EncoderConfigBuilder.swift) supplies rate/GOP/profile/
// color but NO width/height/fps — those come from the resolved capture plan as separate
// `init` params (session create needs w/h; the CFR grid needs fps). U2 `CFRNormalizer`
// (CFRNormalizer.swift) owns ALL slot dedup / hold / drop decisions; this actor only drives
// it with frame PTS (seconds) + ticks. The profile-level VT-constant mapping lives in the
// shared `HEVCProfileLevel.vtProfileLevel` extension (HEVCProfileLevel+VideoToolbox.swift).
// Seam types (`EncodedSampleSink`, `CompressionSession`, `VideoEncoderError`) are in
// VideoEncoderTypes.swift; the live `VTCompressionSession` wrapper is in
// VideoEncoder+LiveSession.swift.
//
// Isolation & memory safety: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
// `actor VideoEncoder` is explicit so the encoder runs off the main actor. Under
// `SWIFT_STRICT_MEMORY_SAFETY = YES` all VideoToolbox / CoreMedia C-interop is wrapped in
// `unsafe` (mirroring CapabilityProbe.swift). `VTCompressionSessionRef` is
// `CM_SWIFT_NONSENDABLE`: created and called ONLY inside the actor's session wrapper, never
// crossing an isolation boundary. The C output callback fires on VT's internal queue and
// recovers a SEPARATE `EncodedSampleSink` (holding only the stream continuation) from the
// refcon — never the actor, never the session.

import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

// file_length / type_body_length are disabled: the actor's length is driven by the lifecycle-
// contract, KNOWN-LIMITATION, and DEFER documentation required on the one-shot lifecycle and
// drop paths. The lifecycle state and continuations are genuinely `private` (file-scoped), so
// the start/stop logic cannot move to a sibling extension file without widening encapsulation —
// the existing +Configuration / +LiveSession splits work only because they touch `internal`
// surface. The catch-up clock + ingest logic requires access to the same private state and
// cannot be split without the same encapsulation cost.
// swiftlint:disable file_length

// MARK: - VideoEncoder

// swiftlint:disable type_body_length
/// A single-stream hardware HEVC encoder.
///
/// One instance encodes exactly one stream (screen OR camera). Frames enter via `ingest`;
/// the CFR clock fills slot gaps with synthetic holds; encoded HEVC samples leave on
/// `encodedSamples`; drops are reported on `drops`.
///
/// ### Constant-frame-rate driving (spec §CFR, OpAC-4.2/4.3)
/// The actor delegates every slot decision to `CFRNormalizer` and its catch-up API.
/// `ingest` calls `catchUpThenEncode`: it emits synthetic holds for any slots that elapsed
/// since the last emission and then encodes the real frame — real frames always win their
/// own slot. `clockTick()` (absolute-deadline loop, or tests via `clockTick(nowSeconds:)`)
/// calls `catchUpHolds` to fill slots that elapsed with no real frame (source silence /
/// static screen). `tick(slotIndex:)` remains available for legacy synchronous test cases.
///
/// ### Anchored PTS (Decision #3 — critical)
/// The PTS handed to `encodeFrame` is the ABSOLUTE host-time value built with exact integer
/// CMTime math from the normalizer's integer `slotIndex` — see `anchoredPTS(slotIndex:)`.
///
/// ### One-shot lifecycle contract (for #34's author)
/// The encoder is ONE-SHOT: `init → start() → (ingest / clockTick / tick)* → stop() → discard`.
/// - `start()` succeeds exactly once. A second `start()` — after a successful start, after
///   `stop()`, or after a failed (throwing) `start()` — throws `VideoEncoderError.invalidLifecycleState`.
///   A thrown `start()` is TERMINAL: the encoder cannot be revived; create a fresh instance.
/// - On any throwing exit from `start()` BOTH output streams (`encodedSamples`, `drops`) are
///   finished, so a consumer that subscribed before `start()` is never left hanging on the
///   HW-hard-fail path.
/// - `stop()` is an unconditional, idempotent terminator: it always finishes both streams even
///   if the session was never created.
/// Because no restart is possible, the internal `CFRNormalizer` is never reused across sessions —
/// the one-shot guarantee structurally removes the stale-normalizer class of bug.
actor VideoEncoder {
    // MARK: - Types

    /// The encoder's one-shot lifecycle state. See the type-level lifecycle contract.
    ///
    /// `nonisolated` so the synthesised `Equatable` witness (used by `state == .idle` inside the
    /// actor) is not inferred `@MainActor` under `InferIsolatedConformances` and stays callable
    /// from the actor's isolation.
    nonisolated private enum State: Equatable {
        /// Constructed, `start()` not yet called.
        case idle
        /// `start()` succeeded; ingest / ticks accepted.
        case running
        /// `stop()` ran OR `start()` threw. Terminal — no further `start()` permitted.
        case stopped
    }

    /// Builds a configured `CompressionSession` for `width × height` with `settings`,
    /// wiring the output to `sink`. Throws `VideoEncoderError.hardwareEncoderUnavailable`
    /// when a HW HEVC session cannot be created (no software fallback). Property-set
    /// failures other than the DataRateLimits fallback surface via the actor as
    /// `RecordingError.encoderSetupFailed`.
    typealias SessionFactory = @Sendable (
        _ width: Int32,
        _ height: Int32,
        _ sink: EncodedSampleSink
    ) throws
        -> any CompressionSession

    // MARK: - Stored state

    // `settings` is `internal` (not `private`): the VideoEncoder+Configuration.swift extension
    // maps it to VT property keys. The rest stay `private`.
    let settings: VTEncoderSettings
    private let width: Int32
    private let height: Int32
    private let fps: Int
    private let anchor: HostTimeAnchor
    private let sessionFactory: SessionFactory

    /// Whether `start()` spawns the standalone CFR clock loop.
    ///
    /// `true` (default): the encoder self-drives its CFR grid — the wall-clock loop fires
    /// `clockTick()` at `1/fps` so holds (OpAC-4.2) work standalone. `false`: an external
    /// coordinator (`RecordingSession` #34, which owns the shared clock) drives `clockTick()`;
    /// also used by tests to drive `tick`/`clockTick`/`ingest` deterministically.
    private let selfClocked: Bool

    /// Lane label used in telemetry lines ("screen" / "camera" / "video").
    /// Additive — callers that do not care pass the default "video".
    private let label: String

    /// `internal` (not `private`): the VideoEncoder+Configuration.swift extension uses it.
    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "VideoEncoder"
    )

    /// Maximum pending frames before a new ingest is gated as backpressure.
    ///
    /// VT has no readiness flag; `pendingFrameCount` is the proxy. A small bound keeps the
    /// pipeline real-time: if the encoder cannot drain within the budget the frame is dropped
    /// rather than queued unbounded (OpAC-4.4).
    private let maxPendingFrames: Int

    /// One-shot lifecycle state. Gates `start()` (idle-only) and `ingest()` (running-only).
    private var state: State = .idle

    private var session: (any CompressionSession)?
    private var sink: EncodedSampleSink?
    private var normalizer = CFRNormalizer()

    /// The last pixel buffer accepted for encoding — re-submitted on a hold (OpAC-4.2).
    /// IOSurface-backed and read-only after ingest (the `VideoFrame` invariant), so
    /// re-submission is zero-copy.
    private var lastPixelBuffer: CVPixelBuffer?

    /// Backpressure counter (`DropReason.encoderBackpressureDrops`). SEPARATE from the
    /// normalizer's `cfrNormalizationDrops`.
    private var encoderBackpressureDrops = 0

    /// Grace window (seconds) given to real frames to arrive before the clock synthesises a hold.
    ///
    /// δ must exceed the p95 (not the mean) of the capture→ingest pipeline latency while
    /// staying below half a slot (8.33 ms @ 60 fps). The 5 ms default was chosen pending an
    /// L5 measurement of the actual p95; measure with `ffprobe -show_frames` on a real
    /// recording and tighten if camera-file quality is still degraded at this value.
    private let graceSeconds: Double

    /// The absolute-deadline CFR clock loop spawned by `start()` and cancelled by `stop()`.
    /// Drives `clockTick()` against the grid's next hold deadline rather than a fixed relative
    /// sleep. Replaced by #34's shared clock once it exists.
    private var clockTickTask: Task<Void, Never>?

    // MARK: - Telemetry

    /// Per-stage cadence accumulator. Flushed every ~1 s on the telemetry tick.
    private var aggregator: StageRateAggregator

    /// ~1 s periodic flush task started in `start()`, cancelled in `stop()`.
    private var telemetryTask: Task<Void, Never>?

    // MARK: - Output streams

    /// Encoded HEVC samples, in decode order, fed by the C output callback via the sink.
    ///
    /// The output stream is `.unbounded` by design for MVP: #32 (FileWriter, local-disk) is
    /// expected to keep up, and a bounded policy would risk dropping a mid-GOP / keyframe sample
    /// and corrupting the bitstream. Sustained-overflow handling (a bounded policy vs. surfacing
    /// a recording failure) is deferred to #32 integration; do NOT add buffering policy here.
    nonisolated let encodedSamples: AsyncStream<EncodedSample>
    private let encodedSamplesContinuation: AsyncStream<EncodedSample>.Continuation

    /// Drop events for `DropMonitor` (#35). One `DropEvent` per backpressure drop.
    ///
    /// Unbounded until #35 (DropMonitor) attaches a consumer; bounding is deferred to #35.
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    // MARK: - Init

    /// Creates a video encoder for one stream.
    ///
    /// The session is NOT created here — call `start()` so creation failures can throw and
    /// be surfaced to the caller (AC-6).
    ///
    /// - Parameters:
    ///   - settings: U1 rate/GOP/profile/color settings.
    ///   - width: Encoded frame width in pixels (from the resolved capture plan).
    ///   - height: Encoded frame height in pixels.
    ///   - fps: CFR grid rate; defines slot spacing `1/fps`. Must be > 0.
    ///   - anchor: Session T0. Defaults to `HostTimeAnchor.now()` for standalone use until
    ///     `RecordingSession` (#34) injects a shared anchor.
    ///   - maxPendingFrames: Backpressure bound. Default 4 (≈ a few frames of slack at 30–60fps).
    ///   - grace: Grace window in seconds given to real frames before the clock synthesises a
    ///     hold. See `graceSeconds` for sizing guidance. Default: 5 ms.
    ///   - selfClocked: Whether `start()` spawns the standalone CFR clock. `true` (default) for
    ///     standalone use; `false` when an external coordinator (#34) or a test drives
    ///     `clockTick()`.
    ///   - label: Lane label emitted in telemetry lines ("screen", "camera"). Default "video" is
    ///     safe for standalone / test use; `LiveEncoderFactory` overrides it per pipeline kind.
    ///   - sessionFactory: Injectable seam. Defaults to the live VideoToolbox implementation;
    ///     tests inject a mock.
    init(
        settings: VTEncoderSettings,
        width: Int32,
        height: Int32,
        fps: Int,
        anchor: HostTimeAnchor = .now(),
        maxPendingFrames: Int = 4,
        grace: Double = 0.005,
        selfClocked: Bool = true,
        label: String = "video",
        sessionFactory: @escaping SessionFactory = VideoEncoder.liveSessionFactory
    ) {
        precondition(fps > 0, "fps must be positive")
        precondition(width > 0 && height > 0, "dimensions must be positive")
        precondition(maxPendingFrames > 0, "maxPendingFrames must be positive")
        precondition(grace >= 0, "grace must be non-negative")

        self.settings = settings
        self.width = width
        self.height = height
        self.fps = fps
        self.anchor = anchor
        self.maxPendingFrames = maxPendingFrames
        self.graceSeconds = grace
        self.selfClocked = selfClocked
        self.label = label
        self.aggregator = StageRateAggregator(lane: label, stage: "encoder", nominalFps: fps)
        self.sessionFactory = sessionFactory

        let (samples, samplesContinuation) = AsyncStream.makeStream(of: EncodedSample.self)
        self.encodedSamples = samples
        self.encodedSamplesContinuation = samplesContinuation

        let (dropEvents, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = dropEvents
        self.dropsContinuation = dropsContinuation
    }

    // MARK: - Test / observation accessors

    /// Normalizer-owned duplicate-slot drop count (`DropReason.cfrNormalizationDrops`).
    var cfrNormalizationDropCount: Int {
        self.normalizer.cfrNormalizationDrops
    }

    /// Encoder-backpressure drop count (`DropReason.encoderBackpressureDrops`). Separate
    /// from `cfrNormalizationDropCount`.
    var backpressureDropCount: Int {
        self.encoderBackpressureDrops
    }

    /// Whether the active session uses a hardware encoder (false when not started).
    /// Drives the L5 HW assertion.
    var isUsingHardwareEncoder: Bool {
        self.session?.usingHardwareEncoder() ?? false
    }

    // MARK: - Lifecycle

    /// Creates and configures the compression session.
    ///
    /// One-shot: succeeds exactly once. See the type-level lifecycle contract.
    ///
    /// - Throws: `VideoEncoderError.invalidLifecycleState` when called on a non-`idle` encoder
    ///   (already started, stopped, or after a failed start); `RecordingError.noHardwareEncoder`
    ///   when no HW HEVC encoder is available (the factory threw, or VT reports
    ///   `UsingHardwareAcceleratedVideoEncoder == false`); `RecordingError.encoderSetupFailed`
    ///   when a mandatory property could not be set.
    ///
    /// Every throwing exit AFTER the lifecycle guard finishes both output streams and marks the
    /// encoder `.stopped` (terminal) — so a pre-`start()` subscriber never hangs and no live HW
    /// session can be created twice. The lifecycle guard itself throws BARE (does not finish
    /// streams or touch the session) so a stray `start()` while `.running` leaves the live
    /// encoder intact.
    func start() throws {
        guard self.state == .idle else {
            self.logger.error("start() called in state \(String(describing: self.state)) — one-shot encoder")
            throw VideoEncoderError.invalidLifecycleState
        }

        let sink = EncodedSampleSink(continuation: self.encodedSamplesContinuation)
        let session: any CompressionSession
        do {
            session = try self.sessionFactory(self.width, self.height, sink)
        } catch {
            // No software fallback (AC-6 / OpAC-4.1). Capture the underlying cause (F9) before
            // collapsing to the hard-fail contract error.
            self.logger.error("Hardware HEVC session creation failed: \(error) — no software fallback")
            throw self.failStart(RecordingError.noHardwareEncoder)
        }

        do {
            try self.configure(session: session)
        } catch {
            session.invalidate()
            throw self.failStart(error)
        }

        // F6: enforce the documented mandatory-HW guarantee (AC-6 / OpAC-4.1). Query ONCE here
        // (not per-frame); query the LOCAL `session` since `self.session` is still nil.
        guard session.usingHardwareEncoder() else {
            self.logger.error("Encoder reported UsingHardwareAcceleratedVideoEncoder == false — no software fallback")
            session.invalidate()
            throw self.failStart(RecordingError.noHardwareEncoder)
        }

        self.session = session
        self.sink = sink
        self.state = .running
        if self.selfClocked {
            self.startClock()
        }
        self.startTelemetryTask()
        self.logger.info("VideoEncoder started — \(self.width)×\(self.height)@\(self.fps)fps")
    }

    /// Common teardown for a throwing `start()` exit: finish BOTH continuations, mark the
    /// encoder terminal, and return the error to rethrow.
    ///
    /// Finishing here guarantees a consumer that subscribed before `start()` is released on the
    /// hard-fail path instead of hanging forever (`Continuation.finish()` is idempotent). The
    /// `.stopped` state makes the failed start terminal — a subsequent `start()` throws.
    private func failStart(_ error: any Error) -> any Error {
        self.state = .stopped
        self.encodedSamplesContinuation.finish()
        self.dropsContinuation.finish()
        return error
    }

    /// Stops the encoder: cancels the CFR clock, drains in-flight frames, tears down the
    /// session, then finishes the output streams.
    ///
    /// Unconditional, idempotent terminator: it ALWAYS finishes both continuations and marks the
    /// encoder `.stopped`, even if the session was never created (e.g. `stop()` before `start()`
    /// or after a failed `start()`) — `finish()` is idempotent. Session teardown is gated on a
    /// live `session`, but stream termination is decoupled from it so `stop()` is always a
    /// reliable terminator.
    ///
    /// Teardown order is load-bearing: the clock task is cancelled AND awaited first so no
    /// tick races teardown; then `completeFrames()` blocks until all in-flight output
    /// callbacks have fired; then `invalidate()` guarantees no further callbacks; and only
    /// THEN are the continuations finished — so no callback ever yields into a finished
    /// continuation.
    func stop() async {
        self.telemetryTask?.cancel()
        self.telemetryTask = nil
        if let session = self.session {
            self.clockTickTask?.cancel()
            await self.clockTickTask?.value
            self.clockTickTask = nil
            session.completeFrames()
            session.invalidate()
            self.session = nil
            self.sink = nil
            self.lastPixelBuffer = nil
        }
        self.state = .stopped
        self.encodedSamplesContinuation.finish()
        self.dropsContinuation.finish()
    }

    // MARK: - CFR clock

    /// Spawns the absolute-deadline CFR clock loop.
    ///
    /// Each iteration sleeps until the next hold-eligible deadline (computed from the grid
    /// anchor and grace window) and then calls `clockTick()`. Sleeping to an absolute
    /// deadline eliminates cumulative drift — a late wakeup is harmless because
    /// `catchUpHolds` emits every slot that elapsed during the overslept period in one
    /// batch. When the grid is not yet open (`lastEmittedSlot == -1`, no real frame
    /// ingested), `clockTick()` cannot emit anything; the loop sleeps a fixed `1/fps`
    /// fallback and retries rather than spinning.
    ///
    /// The clock is the fallback emitter for source silence or a static screen. Real frames
    /// win their own slot via `ingest`; the clock only fills slots that real frames never
    /// claimed.
    ///
    /// Once `RecordingSession` (#34) exists it owns both the source subscription and the
    /// clock and will drive `clockTick()` itself; until then this self-clock keeps the unit
    /// functional standalone.
    private func startClock() {
        // swiftlint:disable:next no_magic_numbers
        let fallbackNanos = UInt64(1_000_000_000 / self.fps)
        self.clockTickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = await self.secondsUntilNextDeadline()
                if let remaining {
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    if Task.isCancelled { return }
                    await self.clockTick()
                } else {
                    // Grid not yet open — no real frame has arrived. Sleep one slot and retry
                    // rather than spinning. clockTick() would be a no-op here anyway.
                    try? await Task.sleep(nanoseconds: fallbackNanos)
                }
            }
        }
    }

    /// Spawns the ~1 s telemetry flush task.
    ///
    /// Uses `ContinuousClock` to measure the actual elapsed interval (not wall time) so that
    /// the `win_s` field in the log line reflects the real measurement window.
    private func startTelemetryTask() {
        self.telemetryTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastInstant = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let elapsed = (now - lastInstant).components
                // swiftlint:disable:next no_magic_numbers
                let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                lastInstant = now
                // Hop into the actor's isolation to mutate the aggregator.
                await self.flushTelemetry(elapsedSeconds: elapsedSeconds)
            }
        }
    }

    private func flushTelemetry(elapsedSeconds: Double) {
        if let line = self.aggregator.flush(elapsedSeconds: elapsedSeconds) {
            telemetryLogger.notice("\(line, privacy: .public)")
        }
    }

    /// Returns the seconds remaining until the next hold-eligible deadline, or `nil` when
    /// the grid is not yet open (no real frame ingested, `lastEmittedSlot == -1`).
    ///
    /// A negative or zero return means the deadline has already passed and `clockTick()`
    /// should be called immediately (catch-up will emit the overdue slots).
    private func secondsUntilNextDeadline() -> Double? {
        guard self.normalizer.lastEmittedSlot >= 0 else { return nil }
        let nowSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime())
        let anchorSeconds = CMTimeGetSeconds(self.anchor.anchorTime)
        let deadline = self.normalizer.nextDeadlineSeconds(
            anchorSeconds: anchorSeconds,
            fps: self.fps,
            graceSeconds: self.graceSeconds
        )
        return deadline - nowSeconds
    }

    /// One wall-clock CFR tick: batch-emit synthetic holds for all grace-expired slots.
    ///
    /// Calls `catchUpHolds` with the current time, emitting holds for every slot whose
    /// window has closed beyond the grace allowance. The cap is `fps` (one second of slots),
    /// bounding the synchronous batch for large catch-up bursts (e.g. after a system sleep).
    /// The read-and-decide is atomic: actor-isolated synchronous code with no `await` inside
    /// the submission loop, so no new frame can arrive mid-batch.
    ///
    /// Real frames win their slot: `ingest` advances `lastEmittedSlot` via `catchUpThenEncode`
    /// before the clock fires, so the clock never re-covers a slot already filled by a real
    /// frame. The clock is the fallback emitter for source silence or a static screen.
    ///
    /// - Note: A large catch-up batch (e.g. after a late wakeup) submits multiple frames
    ///   synchronously. The `pendingFrameCount` proxy cannot drain mid-batch, so holds beyond
    ///   `maxPendingFrames` receive a backpressure drop. Dropping stale holds after a stall is
    ///   consistent with the "atomic read-and-decide" contract and the cap bound.
    func clockTick() {
        let nowSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime())
        self.clockTick(nowSeconds: nowSeconds)
    }

    /// Testable overload: inject `nowSeconds` instead of reading the real clock.
    ///
    /// The production `clockTick()` calls through with `PipelineClock.currentHostTime()`.
    /// Tests drive this directly for deterministic, wall-clock-free assertions.
    func clockTick(nowSeconds: Double) {
        guard self.lastPixelBuffer != nil else { return }
        let anchorSeconds = CMTimeGetSeconds(self.anchor.anchorTime)

        // Measure tick-lag BEFORE catchUpHolds advances the grid — after, nextDeadlineSeconds
        // returns the next window's deadline and the lag measurement would be meaningless.
        if self.normalizer.lastEmittedSlot >= 0 {
            let deadline = self.normalizer.nextDeadlineSeconds(
                anchorSeconds: anchorSeconds,
                fps: self.fps,
                graceSeconds: self.graceSeconds
            )
            // swiftlint:disable:next no_magic_numbers
            let lagMs = abs(nowSeconds - deadline) * 1000
            self.aggregator.recordTickLag(lagMs: lagMs)
        }

        let emission = self.normalizer.catchUpHolds(
            nowSeconds: nowSeconds,
            anchorSeconds: anchorSeconds,
            fps: self.fps,
            graceSeconds: self.graceSeconds,
            cap: self.fps
        )
        if !emission.slots.isEmpty {
            self.aggregator.recordCatchupBatch(size: emission.slots.count)
        }
        for slot in emission.slots {
            // lastPixelBuffer cannot be nil here: the guard above ensures it.
            // All slots from catchUpHolds are isHold==true by contract.
            let pts = self.anchoredPTS(slotIndex: slot.slotIndex)
            // swiftlint:disable:next force_unwrapping
            self.submit(pixelBuffer: self.lastPixelBuffer!, slotIndex: slot.slotIndex, detectedAt: pts)
        }
    }

    // MARK: - Ingest (new frame)

    /// Ingests a new captured frame.
    ///
    /// Routes the frame through the catch-up emission API. Frames that map to a slot already
    /// emitted (duplicates) or to a negative slot (pre-anchor) are routed through
    /// `processFrame` solely for its drop-accounting side effect — `cfrNormalizationDrops`
    /// and pre-anchor accounting stay byte-identical to the old path.
    ///
    /// For valid new frames, `catchUpThenEncode` emits any synthetic holds for slots that
    /// elapsed since the last emission, then emits the real frame. This eliminates the
    /// hold-beats-real race: the real frame claims its slot atomically here before the clock
    /// can touch it.
    ///
    /// Input frames always arrive with `isHoldRepeat == false`; this encoder owns the hold
    /// decision via the normalizer.
    func ingest(_ frame: VideoFrame) {
        // F7: not-running guard. Frames arriving before start() or after stop() are dropped;
        // log it rather than swallow silently. No DropEvent (that taxonomy is #35 scope).
        guard self.state == .running else {
            self.logger.warning("ingest called while encoder not running — frame dropped")
            return
        }
        let ptsSeconds = CMTimeGetSeconds(frame.ptsHostTime)
        let anchorSeconds = CMTimeGetSeconds(self.anchor.anchorTime)

        // Route duplicates and pre-anchor frames through processFrame for accounting only.
        // slotFor uses the same round() mapping as processFrame, so agreement is guaranteed.
        let slotS = CFRNormalizer.slotFor(ptsSeconds: ptsSeconds, anchorSeconds: anchorSeconds, fps: self.fps)
        if slotS < 0 || slotS <= self.normalizer.lastEmittedSlot {
            let decision = self.normalizer.processFrame(
                ptsSeconds: ptsSeconds, anchorSeconds: anchorSeconds, fps: self.fps
            )
            // Defensive: processFrame must return .drop for frames routed here.
            // An .encode result would indicate a mapping mismatch — assert rather than silently encode.
            if case .encode = decision {
                // Mapping mismatch — slotFor and processFrame must agree on the routing.
                assertionFailure("ingest: processFrame returned .encode for a frame expected to drop " +
                    "(slot \(slotS), lastEmitted \(self.normalizer.lastEmittedSlot))")
            }
            self.aggregator.recordDropDup()
            return
        }

        // Valid new frame: emit holds for any elapsed slots, then the real frame.
        self.aggregator.recordFresh()
        let emission = self.normalizer.catchUpThenEncode(
            ptsSeconds: ptsSeconds, anchorSeconds: anchorSeconds, fps: self.fps, cap: self.fps
        )
        self.submitEmission(emission, frame: frame, computedSlot: slotS)
    }

    /// Iterates a `CFREmission` produced by `catchUpThenEncode` and submits each slot.
    ///
    /// Hold slots re-submit `lastPixelBuffer`; the terminal real slot updates it first.
    /// Extracted from `ingest` to stay within the function-body-length limit.
    private func submitEmission(_ emission: CFREmission, frame: VideoFrame, computedSlot: Int) {
        var holdCount = 0
        for slot in emission.slots {
            if slot.isHold {
                // Hold: re-submit last known buffer. lastPixelBuffer is non-nil here because
                // catchUpThenEncode only emits holds when lastEmittedSlot >= 0, which means at
                // least one real frame has been ingested before this one (stage-(a) contract:
                // no leading holds on the first frame).
                guard let holdBuffer = self.lastPixelBuffer else {
                    assertionFailure("ingest: hold emitted but lastPixelBuffer is nil — stage-(a) contract violated")
                    continue
                }
                let holdPTS = self.anchoredPTS(slotIndex: slot.slotIndex)
                self.submit(pixelBuffer: holdBuffer, slotIndex: slot.slotIndex, detectedAt: holdPTS)
                self.aggregator.recordHold()
                holdCount += 1
            } else {
                // Real frame: update lastPixelBuffer before submitting so subsequent holds
                // in a future batch (or from the clock) re-use the fresh content.
                self.lastPixelBuffer = frame.pixelBuffer
                self.submit(pixelBuffer: frame.pixelBuffer, slotIndex: slot.slotIndex, detectedAt: frame.ptsHostTime)
                self.aggregator.recordEncodedReal()
            }
        }
        if holdCount > 0 {
            self.aggregator.recordCatchupBatch(size: holdCount)
        }
        if emission.cappedShort {
            // The hold count exceeded `cap` (fps); the real frame's slot was not included.
            // Its content is consciously deferred — see catchUpThenEncode stage-(a) contract.
            self.logger.debug("ingest: catch-up capped short at slot \(computedSlot) — real frame deferred")
        }
    }

    // MARK: - CFR tick (hold)

    /// Drives a CFR clock tick for `slotIndex` when no new frame arrived for that slot.
    ///
    /// On a hold the LAST `CVPixelBuffer` is re-submitted with the held slot's anchored PTS
    /// (OpAC-4.2). `cfrNormalizationDrops` is NOT incremented for a hold. Exposed for the
    /// wall-clock timer AND for synchronous L2 tests (no `Task.sleep` in tests).
    ///
    /// - Parameter slotIndex: The CFR grid slot that elapsed with no frame.
    func tick(slotIndex: Int) {
        guard let lastPixelBuffer = self.lastPixelBuffer else {
            // No frame has ever been ingested — nothing to hold. The first real frame will
            // open the grid.
            return
        }

        let decision = self.normalizer.processTick(slotIndex: slotIndex, fps: self.fps)
        switch decision {
        case let .encode(slotIndex, _, _):
            let pts = self.anchoredPTS(slotIndex: slotIndex)
            self.submit(pixelBuffer: lastPixelBuffer, slotIndex: slotIndex, detectedAt: pts)

        case .drop:
            break
        }
    }

    // MARK: - Submission + backpressure

    /// Submits one pixel buffer to the session at the anchored PTS for `slotIndex`.
    ///
    /// Backpressure gate (OpAC-4.4): if the session already has `maxPendingFrames` in flight,
    /// the frame is dropped as `encoderBackpressureDrops` and a `DropEvent` is emitted. This
    /// counter is SEPARATE from the normalizer's `cfrNormalizationDrops`.
    private func submit(pixelBuffer: CVPixelBuffer, slotIndex: Int, detectedAt: CMTime) {
        guard let session = self.session else { return }

        if session.pendingFrameCount() >= self.maxPendingFrames {
            self.encoderBackpressureDrops += 1
            self.aggregator.recordGateDrop()
            self.dropsContinuation.yield(
                DropEvent(reason: .encoderBackpressureDrops, count: 1, detectedAt: detectedAt)
            )
            self.logger.warning("Encoder backpressure — dropped frame at slot \(slotIndex)")
            return
        }

        let pts = self.anchoredPTS(slotIndex: slotIndex)
        // Slot duration is exactly one grid step.
        let duration = CMTimeMake(value: 1, timescale: Int32(self.fps))
        let status = session.encodeFrame(pixelBuffer: pixelBuffer, pts: pts, duration: duration)
        if status != noErr {
            // F2 / KNOWN LIMITATION: the normalizer already advanced `lastEmittedSlot`, so a
            // non-noErr encode is a permanent invisible gap in the CFR grid. For MVP this is
            // surfaced as a telemetry counter (vt_err) and logged — surfacing to DropMonitor is
            // deferred to #35, which owns the drop-reason taxonomy. It is deliberately NOT counted
            // on `encoderBackpressureDrops` (that would corrupt the OpAC-4.3/4.4 counter
            // separation) and NOT on `cfrNormalizationDrops` (normalizer-owned).
            self.aggregator.recordVTError()
            self.logger.error("VTCompressionSessionEncodeFrame failed: \(status) at slot \(slotIndex) — frame dropped")
        } else {
            // Count successful encodeFrame submissions as emitted slots.
            // Counted here (actor-isolated) rather than from the VT output callback, which fires
            // on VT's internal queue and has no access to the actor-isolated aggregator.
            self.aggregator.recordEmit()
        }
    }

    /// Builds the ABSOLUTE host-time anchored PTS for a CFR slot.
    ///
    /// `CMTimeAdd(anchor, CMTimeMake(value: slotIndex, timescale: fps))` — exact integer
    /// rational CMTime math, NOT a Double-seconds round-trip and NOT a bare
    /// `CMTime(value: slotIndex, …)` (which would drop the anchor → relative time and
    /// silently corrupt every timestamp #32 rebases). Decision #3 of the plan.
    private func anchoredPTS(slotIndex: Int) -> CMTime {
        let slotOffset = CMTimeMake(value: CMTimeValue(slotIndex), timescale: Int32(self.fps))
        return CMTimeAdd(self.anchor.anchorTime, slotOffset)
    }
}

// swiftlint:enable type_body_length
