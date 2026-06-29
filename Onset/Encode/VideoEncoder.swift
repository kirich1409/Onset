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
/// static screen).
///
/// ### Anchored PTS (Decision #3 — critical)
/// The PTS handed to `encodeFrame` is the ABSOLUTE host-time value built with exact integer
/// CMTime math from the normalizer's integer `slotIndex` — see `anchoredPTS(slotIndex:)`.
///
/// ### One-shot lifecycle contract (for #34's author)
/// The encoder is ONE-SHOT: `init → start() → (ingest / clockTick)* → stop() → discard`.
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
    /// also used by tests to drive `clockTick`/`ingest` deterministically.
    private let selfClocked: Bool

    /// Lane label used in telemetry lines ("screen" / "camera" / "video").
    /// Additive — callers that do not care pass the default "video".
    private let label: String

    /// Maps the lane label to the appropriate `DropSource` case for `DropEvent` emission.
    /// "video" (test default) is treated as the screen lane — `DropSource.encodeScreen`.
    private var encodeDropSource: DropSource {
        switch self.label {
        case "screen":
            .encodeScreen

        case "camera":
            .encodeCamera

        default:
            // "video" is the test default and maps to screen; any unexpected label is safe here.
            .encodeScreen
        }
    }

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
    /// normalizer's `cfrNormalizationDrops`. Counts ONLY real-content frames dropped at the gate.
    private var encoderBackpressureDrops = 0

    /// Synthetic-hold drop counter (`DropReason.encoderHoldDrops`). SEPARATE from
    /// `encoderBackpressureDrops`: counts catch-up hold frames (repeats of `lastPixelBuffer`)
    /// dropped at the gate during a post-stall/sleep batch. A dropped hold loses no user content,
    /// so it must never feed the degraded latch or the user-facing dropped-frames count (#200).
    private var encoderHoldDrops = 0

    /// Per-lane latency-aware grace estimator (#268). Tracks the upper envelope of the
    /// capture→ingest latency Δ and maps it to the CFR hold grace, so a high-latency lane
    /// (Continuity Camera, Δ ≈ 100–200 ms) widens grace enough for real frames to reach
    /// their capture-PTS slot before a synthetic hold fills it. Read FRESH every scheduling
    /// cycle by both grace consumers; fed via `observe` on every post-anchor frame.
    ///
    /// `grace == nil` (default, production) builds an ADAPTIVE latency-aware estimator: a
    /// pessimistic cold-start at `ceiling` (≈ 0.5 s) relaxing toward the per-fps floor
    /// `LatencyGraceEstimator.defaultGrace(fps)`, with the ceiling capping envelope growth
    /// so a stalled source cannot inflate grace without bound. An explicit `grace:` pins a
    /// CONSTANT estimator (deterministic tests / static-grace lanes — "do not adapt").
    /// Replaces the former static `graceSeconds` field.
    private var graceEstimator: LatencyGraceEstimator

    /// Whether the capture→ingest Δ anomaly (clock inversion / invalid `CMTime`) has already
    /// been logged this session. The grace estimator silently ignores such a Δ; this latch
    /// surfaces it ONCE via the logger without spamming the 30–60/s ingest hot path (#268).
    private var loggedLatencyAnomaly = false

    /// Session T0 in seconds, derived once at init from `anchor.anchorTime`.
    /// Avoids repeated `CMTimeGetSeconds` calls in hot paths (`ingest`, `clockTick`, `secondsUntilNextDeadline`).
    private let anchorSeconds: Double

    /// The absolute-deadline CFR clock loop spawned by `start()` and cancelled by `stop()`.
    /// Drives `clockTick()` against the grid's next hold deadline rather than a fixed relative
    /// sleep. Replaced by #34's shared clock once it exists.
    private var clockTickTask: Task<Void, Never>?

    // MARK: - Telemetry

    /// Per-stage cadence accumulator. Flushed every ~1 s on the telemetry tick.
    private var aggregator: StageRateAggregator

    /// ~1 s periodic flush task started in `start()`, cancelled in `stop()`.
    private var telemetryTask: Task<Void, Never>?

    /// Maximum holds to emit in one batch — capped at 1 second of slots to bound
    /// synchronous burst work after a late wakeup or system sleep.
    private var holdCapSlots: Int {
        self.fps
    }

    // MARK: - Output streams

    /// Encoded HEVC samples, in decode order, fed by the C output callback via the sink.
    ///
    /// The output stream is `.unbounded` by design for MVP: #32 (FileWriter, local-disk) is
    /// expected to keep up, and a bounded policy would risk dropping a mid-GOP / keyframe sample
    /// and corrupting the bitstream. Sustained-overflow handling (a bounded policy vs. surfacing
    /// a recording failure) is deferred to #32 integration; do NOT add buffering policy here.
    nonisolated let encodedSamples: AsyncStream<EncodedSample>
    private let encodedSamplesContinuation: AsyncStream<EncodedSample>.Continuation

    /// Drop events for `DropMonitor` (#35). One `DropEvent` per backpressure drop (real or hold)
    /// AND one per CFR-normalization dup-drop (`.cfrNormalizationDrops`, #268 T-4) — the latter
    /// routed by `DropMonitor` as never-degrading, so it is visible in tech-info without flipping
    /// the degraded latch.
    ///
    /// Intentionally `.unbounded` (do NOT change the buffering policy): the consumer is
    /// `DropMonitor` (#36, `RecordingSession.swift:517,574`), which counts EVERY drop event —
    /// a `.bufferingNewest` policy would undercount `cfrNormalizationDrops` and corrupt the
    /// user-facing counter, where per-event accuracy matters.
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
    ///     With `allowFrameReordering=false` (production default since issue #104) the encoder's
    ///     steady-state pending depth is ≤2, so 4 is a conservative headroom bound rather than a
    ///     tight calibration against the B-frame reorder window.
    ///   - grace: Source-silence threshold in seconds — the clock waits this long after a slot's
    ///     midpoint before synthesising a hold. `nil` (default, production) builds an adaptive
    ///     latency-aware estimator (pessimistic cold-start at ceiling ≈ 0.5 s, relaxing to the
    ///     per-fps floor `LatencyGraceEstimator.defaultGrace(fps)`). An explicit value pins a
    ///     constant grace (tests / static-grace lanes) — pass one only to override the default.
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
        grace: Double? = nil,
        selfClocked: Bool = true,
        label: String = "video",
        sessionFactory: @escaping SessionFactory = VideoEncoder.liveSessionFactory
    ) {
        precondition(fps > 0, "fps must be positive")
        precondition(width > 0 && height > 0, "dimensions must be positive")
        precondition(maxPendingFrames > 0, "maxPendingFrames must be positive")
        if let grace { precondition(grace >= 0, "grace must be non-negative") }

        self.settings = settings
        self.width = width
        self.height = height
        self.fps = fps
        self.anchor = anchor
        self.anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        self.maxPendingFrames = maxPendingFrames
        // Explicit grace pins a constant (test determinism / static-grace lanes); nil selects
        // the adaptive estimator with a pessimistic cold-start (#268, production path).
        if let grace {
            self.graceEstimator = LatencyGraceEstimator(constant: grace)
        } else {
            self.graceEstimator = LatencyGraceEstimator(ceiling: LatencyGraceEstimator.defaultCeilingSeconds)
        }
        self.selfClocked = selfClocked
        self.label = label
        self.aggregator = StageRateAggregator(lane: label, stage: .encoder, nominalFps: fps)
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
    /// from `cfrNormalizationDropCount`. Counts ONLY real-content frame gate drops.
    var backpressureDropCount: Int {
        self.encoderBackpressureDrops
    }

    /// Synthetic-hold gate-drop count (`DropReason.encoderHoldDrops`). Separate from
    /// `backpressureDropCount` — these are dropped catch-up holds and carry no user content (#200).
    var holdDropCount: Int {
        self.encoderHoldDrops
    }

    /// Test-only observation accessor for telemetry accounting; not part of the encoder's
    /// production contract. Used by L2 tests to verify clock-driven holds are counted.
    var aggregatorHoldsCount: Int {
        self.aggregator.holdsCount
    }

    /// Test-only observation accessor for telemetry accounting; not part of the encoder's
    /// production contract. Used by L2 tests to verify cappedShort batches are counted.
    var aggregatorCapOverflowCount: Int {
        self.aggregator.capOverflowCount
    }

    /// Test-only observation accessor; exposes the maximum tick-lag recorded since the last
    /// flush. Used by L2 tests to verify the fixed tick-lag semantics (wake-up latency only).
    var aggregatorTickLagMaxMs: Double {
        self.aggregator.tickLagMaxMs
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
        // .userInitiated keeps the loop responsive; the clock drives real-time A/V emission.
        self.clockTickTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = await self.secondsUntilNextDeadline()
                if let remaining {
                    // Capture the absolute target deadline BEFORE sleeping so the lag
                    // measurement reflects the actual wake-up latency, not any post-wake
                    // grid advancement (which would report ~1 slot period on a healthy pipeline).
                    let targetDeadlineSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime()) + remaining
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    if Task.isCancelled { return }
                    let nowSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime())
                    await self.clockTick(nowSeconds: nowSeconds, targetDeadlineSeconds: targetDeadlineSeconds)
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
                let elapsedSeconds = (now - lastInstant).totalSeconds
                lastInstant = now
                // Hop into the actor's isolation to mutate the aggregator.
                await self.flushTelemetry(elapsedSeconds: elapsedSeconds)
            }
        }
    }

    private func flushTelemetry(elapsedSeconds: Double) {
        if let line = self.aggregator.flush(elapsedSeconds: elapsedSeconds) {
            telemetryLogger.notice("\(line, privacy: .public)")
        } else {
            self.logger.debug("flushTelemetry: skipped (elapsed ≤ 0)")
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
        // INVARIANT: `effectiveGrace` is read FRESH here every scheduling cycle (the deadline is
        // recomputed per tick). If the envelope changes between planning a sleep and the tick, the
        // worst case is one extra sleep on the recomputed deadline — never a busy-spin (#268 B2).
        let deadline = self.normalizer.nextDeadlineSeconds(
            anchorSeconds: self.anchorSeconds,
            fps: self.fps,
            graceSeconds: self.graceEstimator.effectiveGrace(fps: self.fps)
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
    func clockTick(nowSeconds: Double, targetDeadlineSeconds: Double) {
        // Wake-up latency: how far past the targeted deadline we actually woke up.
        // max(0,…) clamps early wakes (scheduler jitter) to zero.
        // swiftlint:disable:next no_magic_numbers
        self.aggregator.recordTickLag(lagMs: max(0, nowSeconds - targetDeadlineSeconds) * 1000)
        self.clockTick(nowSeconds: nowSeconds)
    }

    /// Test-only entry: drives a clock tick at an injected `nowSeconds` without recording
    /// tick-lag (no target deadline is available in this path).
    ///
    /// Production code calls `clockTick(nowSeconds:targetDeadlineSeconds:)` via `startClock()`.
    /// Tests drive this directly for deterministic, wall-clock-free assertions.
    func clockTick(nowSeconds: Double) {
        guard let lastPixelBuffer = self.lastPixelBuffer else { return }

        // INVARIANT: `effectiveGrace` is read FRESH here every tick (the deadline that scheduled
        // this tick was computed with the same per-tick read in `secondsUntilNextDeadline`). A
        // grace change between planning and tick yields another sleep, not a busy-spin (#268 B2).
        let emission = self.normalizer.catchUpHolds(
            nowSeconds: nowSeconds,
            anchorSeconds: self.anchorSeconds,
            fps: self.fps,
            graceSeconds: self.graceEstimator.effectiveGrace(fps: self.fps),
            cap: self.holdCapSlots
        )
        if !emission.slots.isEmpty {
            self.aggregator.recordCatchupBatch(size: emission.slots.count)
        }
        for slot in emission.slots {
            // All slots from catchUpHolds are isHold==true by contract — synthetic repeats of
            // lastPixelBuffer. A gate-drop here is `.encoderHoldDrops`, not a degradation (#200).
            let pts = self.anchoredPTS(slotIndex: slot.slotIndex)
            self.submit(
                pixelBuffer: lastPixelBuffer, slotIndex: slot.slotIndex, pts: pts, detectedAt: pts, isHold: true
            )
            self.aggregator.recordHold()
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
        // Production path: read the real host clock for the capture→ingest Δ; the test-only
        // `nowSeconds` entry injects it for deterministic cold-start assertions instead.
        self.ingest(frame, nowSeconds: CMTimeGetSeconds(PipelineClock.currentHostTime()))
    }

    /// Test-only entry: ingests a frame with an injected host-clock `nowSeconds` as the Δ
    /// reference, without reading `PipelineClock`.
    ///
    /// Production calls `ingest(_:)`, which forwards the real host time here; tests drive this
    /// directly for deterministic, wall-clock-free Δ / cold-start assertions (mirrors the
    /// `clockTick(nowSeconds:)` seam).
    ///
    /// - Parameters:
    ///   - frame: The captured frame to ingest.
    ///   - nowSeconds: Injected host-clock "now" in seconds; Δ = `nowSeconds − capturePTS`.
    func ingest(_ frame: VideoFrame, nowSeconds: Double) {
        let ingestStart = ContinuousClock.now
        defer { self.aggregator.recordIngest(durationMs: self.elapsedMs(from: ingestStart)) }

        // F7: not-running guard. Frames arriving before start() or after stop() are dropped;
        // log it rather than swallow silently. No DropEvent (that taxonomy is #35 scope).
        guard self.state == .running else {
            self.logger.warning("ingest called while encoder not running — frame dropped")
            return
        }
        let ptsSeconds = CMTimeGetSeconds(frame.ptsHostTime)

        // Capture→ingest latency Δ = host-clock now − capture PTS. `nowSeconds` is the host clock
        // (`ContinuousClock.now` above is a different clock, for telemetry only). Feeds the grace
        // estimator on every post-anchor frame below (#268).
        let delta = nowSeconds - ptsSeconds

        // Diagnostic (project rule: suppression must not be silent). `observe` silently ignores a
        // clock-inversion (Δ < 0) or invalid-`CMTime` (NaN / ∞) Δ; surface it ONCE per session so a
        // clock-domain desync is visible in logs without spamming the 30–60/s hot path. Pure
        // diagnostic — it does not alter the flow.
        if !delta.isFinite || delta < 0, !self.loggedLatencyAnomaly {
            self.loggedLatencyAnomaly = true
            self.logger.warning(
                "capture→ingest Δ anomaly (Δ=\(delta)s): clock-domain desync or invalid CMTime — grace ignores it"
            )
        }

        // Route duplicates and pre-anchor frames through processFrame for accounting only.
        // slotFor uses the same round() mapping as processFrame, so agreement is guaranteed.
        let slotS = CFRNormalizer.slotFor(ptsSeconds: ptsSeconds, anchorSeconds: self.anchorSeconds, fps: self.fps)
        if slotS < 0 || slotS <= self.normalizer.lastEmittedSlot {
            // Post-anchor dup frames (slotS >= 0) are the ONLY latency signal once the freeze starts
            // — they never reach the non-dup path that updates `lastPixelBuffer`/feeds the estimator,
            // so observing here keeps grace growing exactly when it must (#268). Pre-anchor frames
            // (slotS < 0) carry an inflated Δ (pts < anchor) and are excluded so they cannot poison
            // the upper envelope.
            if slotS >= 0 {
                self.graceEstimator.observe(latencySeconds: delta)
                // Observability (#268 T-4): surface the CFR dup-drop as a DropEvent so DropMonitor /
                // tech-info ("Нормализация CFR") is no longer blind to it. Uses the SHARED
                // `DropReason.cfrNormalizationDrops` (PipelineTypes) — NOT the local CFRDropReason.
                // DropMonitor routes this reason as never-degrading, so no false "Degraded" on
                // Continuity. `recordDropDup` below stays (drop_dup telemetry, a separate sink — no
                // double count).
                let dropSource = self.encodeDropSource
                self.dropsContinuation.yield(DropEvent(
                    reason: .cfrNormalizationDrops, source: dropSource, count: 1, detectedAt: frame.ptsHostTime
                ))
            }
            let decision = self.normalizer.processFrame(
                ptsSeconds: ptsSeconds, anchorSeconds: self.anchorSeconds, fps: self.fps
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
        // Feed the grace estimator on the non-dup path too (post-anchor by construction here).
        self.graceEstimator.observe(latencySeconds: delta)
        let emission = self.normalizer.catchUpThenEncode(
            ptsSeconds: ptsSeconds, anchorSeconds: self.anchorSeconds, fps: self.fps, cap: self.holdCapSlots
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
                self.submit(
                    pixelBuffer: holdBuffer, slotIndex: slot.slotIndex, pts: holdPTS, detectedAt: holdPTS, isHold: true
                )
                self.aggregator.recordHold()
                holdCount += 1
            } else {
                // Real frame: update lastPixelBuffer before submitting so subsequent holds
                // in a future batch (or from the clock) re-use the fresh content.
                self.lastPixelBuffer = frame.pixelBuffer
                let realPTS = self.anchoredPTS(slotIndex: slot.slotIndex)
                self.submit(
                    pixelBuffer: frame.pixelBuffer,
                    slotIndex: slot.slotIndex,
                    pts: realPTS,
                    detectedAt: frame.ptsHostTime,
                    isHold: false
                )
                self.aggregator.recordEncodedReal()
            }
        }
        if holdCount > 0 {
            self.aggregator.recordCatchupBatch(size: holdCount)
        }
        if emission.cappedShort {
            // The hold count exceeded `cap` (fps); the real frame's slot was not included.
            // Its content is consciously deferred — see catchUpThenEncode stage-(a) contract.
            self.logger.warning("ingest: catch-up capped short at slot \(computedSlot) — real frame deferred")
            self.aggregator.recordCapOverflow()
        }
    }

    // MARK: - Duration measurement helper

    /// Returns the elapsed time in milliseconds since `startInstant` (from `ContinuousClock`).
    ///
    /// Uses integer arithmetic on `components` to avoid `CVarArg` and satisfy
    /// `SWIFT_STRICT_MEMORY_SAFETY`. Called from `submit` and `ingest` to record
    /// per-call durations without importing a second clock type.
    nonisolated private func elapsedMs(from startInstant: ContinuousClock.Instant) -> Double {
        // swiftlint:disable:next no_magic_numbers
        (ContinuousClock.now - startInstant).totalSeconds * 1000
    }

    // MARK: - Submission + backpressure

    /// Submits one pixel buffer to the session at the pre-computed `pts` for `slotIndex`.
    ///
    /// The caller is responsible for computing `pts` via `anchoredPTS(slotIndex:)` — this
    /// avoids redundant computation when holds are submitted from `submitEmission`.
    ///
    /// Backpressure gate (OpAC-4.4): pending >= maxPendingFrames → the frame is dropped and a
    /// `DropEvent` is emitted. The drop reason branches on `isHold`:
    /// - `isHold == false` (real captured content) → `.encoderBackpressureDrops`, increments
    ///   `encoderBackpressureDrops`. This is the only counter that drives the degraded latch.
    /// - `isHold == true` (synthetic catch-up repeat) → `.encoderHoldDrops`, increments
    ///   `encoderHoldDrops`. A dropped hold loses no user content, so it must NOT degrade (#200).
    /// Both counters are SEPARATE from the normalizer's `cfrNormalizationDrops`.
    ///
    /// - Parameter isHold: Whether the submitted buffer is a synthetic hold (catch-up repeat of
    ///   `lastPixelBuffer`) rather than a freshly captured frame. The caller classifies this.
    private func submit(
        pixelBuffer: CVPixelBuffer,
        slotIndex: Int,
        pts: CMTime,
        detectedAt: CMTime,
        isHold: Bool
    ) {
        guard let session = self.session else { return }

        let pendingQueryStart = ContinuousClock.now
        let pending = session.pendingFrameCount()
        self.aggregator.recordPendingQuery(durationMs: self.elapsedMs(from: pendingQueryStart))
        self.aggregator.recordPendingValue(pending)

        if pending >= self.maxPendingFrames {
            self.aggregator.recordGateDrop()
            let reason: DropReason
            if isHold {
                // Synthetic hold dropped — no user content lost; never drives the degraded latch.
                self.encoderHoldDrops += 1
                reason = .encoderHoldDrops
            } else {
                // Real captured frame dropped — this is the degradation signal (OpAC-4.3/4.4).
                self.encoderBackpressureDrops += 1
                reason = .encoderBackpressureDrops
            }
            self.dropsContinuation.yield(
                DropEvent(reason: reason, source: self.encodeDropSource, count: 1, detectedAt: detectedAt)
            )
            return
        }

        // Slot duration is exactly one grid step.
        let duration = CMTimeMake(value: 1, timescale: Int32(self.fps))
        let encodeStart = ContinuousClock.now
        let status = session.encodeFrame(pixelBuffer: pixelBuffer, pts: pts, duration: duration)
        self.aggregator.recordEncodeCall(durationMs: self.elapsedMs(from: encodeStart))
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
