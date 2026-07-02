// StabilizingVideoSource.swift
// Onset
//
// #297 — the camera-stabilization stage as a dual-facet decorator over `CameraSource`.
//
// Data flow: `CameraSource.frames` → [depth-1 slot → work task → estimation → smoother → render]
// → own bounded `frames` stream → `VideoEncoder.ingest`. `audioSamples` / `events` forward to the
// wrapped source untouched; `drops` is an OWN stream merging the wrapped source's drops (original
// attribution preserved) with the stage's drops (`DropSource.stabilizeCamera`).
//
// Eager-drain policy (attribution invariant): the input drain NEVER suspends on stage work —
// every arrived frame immediately lands in a depth-1 newest-wins slot; a displaced frame becomes
// `DropEvent(.stabilizeCamera, .stabilizationDrops)`. Without the slot, a Vision latency spike
// (85–250 ms outliers) would back the overflow up into the wrapped source's own
// `.bufferingNewest(4)` stream, the loss would be attributed to CAPTURE counters, and the bypass
// trigger would never see its own signal.
//
// One-shot lifecycle (project invariant): `start()` succeeds once, a throwing `start()` is
// terminal, `stop()` is idempotent. Stop order mirrors `VideoEncoder.stop()`'s join discipline:
// wrapped.stop → drain joins (input tail) → work joins (in-flight frame lands) → own streams
// finish → GPU resources released. No frame is lost on a graceful stop.

import CoreGraphics
import CoreMedia
import Foundation
import os

// MARK: - StabilizingVideoSource

/// Actor decorator adding real-time translational stabilization to the camera RECORD path (#297).
///
/// Wraps the record `CameraSource` behind the same `VideoFrameSource & AudioSampleSource`
/// contract, so `RecordingSession` wiring is unchanged; `LiveSourceFactory` inserts the decorator
/// only when `ResolvedCameraPlan.stabilization` is present (AC-3: OFF = identical wiring).
/// The preview `CameraSource` is never wrapped — the preview shows the raw, uncropped image by
/// design (framing aid, not WYSIWYG; communicated by the settings footer).
actor StabilizingVideoSource: VideoFrameSource, AudioSampleSource {
    // MARK: Constants

    /// Output `frames` buffer depth — the protocol's bounded-buffer contract, matched to
    /// `CameraSource`'s own frame depth so the decorator is transparent to the encoder.
    private static let framesBufferDepth = 4

    /// Merged `drops` buffer depth (mirrors `CameraSource.dropsBufferDepth`).
    private static let dropsBufferDepth = 8

    // MARK: Logging

    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "StabilizingVideoSource"
    )

    // MARK: Protocol streams

    /// Stabilized frames toward the encoder. Bounded (`.bufferingNewest(4)`); an overflow is
    /// REAL content loss caused by a slow downstream — emitted as
    /// `DropEvent(.encoderBackpressureDrops, .stabilizeCamera)` (feeds the degraded window).
    nonisolated let frames: AsyncStream<VideoFrame>
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation

    /// Merged drop channel: wrapped source's events pass through with their ORIGINAL
    /// source/reason; the stage adds its own `.stabilizeCamera` events.
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    /// Lifecycle events forward to the wrapped source untouched (camera disconnect handling in
    /// `RecordingSession` keeps working against the decorator).
    nonisolated var events: AsyncStream<SourceEvent> {
        self.wrapped.events
    }

    /// Microphone samples forward to the wrapped source untouched (the mic rides the camera
    /// `AVCaptureSession`; the stage never touches audio).
    nonisolated var audioSamples: AsyncStream<AudioSample> {
        self.wrapped.audioSamples
    }

    // MARK: Wiring

    /// The wrapped record camera (video + mic facets, one object).
    private let wrapped: any VideoFrameSource & AudioSampleSource

    /// The estimation+render seam. Live: `StabilizationRenderer`; tests: a fake stage.
    private let stage: any StabilizationStage

    /// Session-fixed geometry from the resolved plan.
    private let stabilization: ResolvedCameraPlan.StabilizationPlan

    /// Correction scale from 1080p-equivalent to plan pixels (`planWidth / 1920`).
    private let planScale: Double

    /// The depth-1 newest-wins estimation slot between the drain and the work task.
    private let slotStream: AsyncStream<VideoFrame>
    private let slotContinuation: AsyncStream<VideoFrame>.Continuation

    // MARK: Stage state

    /// The stage's processing phase. One-directional: `warmUp → stabilizing → bypass`
    /// (no return from bypass within a session).
    private enum Phase {
        /// Measuring the real cadence; frames render with correction = 0.
        case warmUp
        /// Steady state: estimate → smooth → render with the chosen scale.
        case stabilizing(estScale: Int)
        /// Degraded: estimation stopped, session-fixed geometry still renders, correction
        /// ramps to zero.
        case bypass
    }

    private var phase: Phase = .warmUp

    /// Whether `stage.activateEstimation` has run (buffers exist). Deactivated lazily by the
    /// work task after a bypass transition so the release is serialized with in-flight work.
    private var estimationActivated = false

    /// Warm-up cadence meter (pure).
    private var warmUp: StabilizationWarmUp

    /// Median warm-up interval, kept for the AC-8 report line.
    private var warmUpMedianIntervalMs: Double?

    /// The estimation scale chosen by warm-up (2 or 3), for diagnostics.
    private var chosenEstScale: Int?

    /// Bypass trigger (1): slot-eviction overload detector (pure).
    private var overloadDetector: StabilizationOverloadDetector

    /// The causal lock-with-slow-recenter smoother (pure), in 1080p-equivalent coordinates.
    private var smoother = StabilizationSmoother()

    /// The correction applied to the previous frame, PLAN pixels. Reused on estimation freeze;
    /// ramped toward zero in bypass.
    private var lastCorrectionPlan = StabilizationVector.zero

    /// Bypass trigger (2): consecutive estimation/render errors. Reset by a fully successful
    /// frame; pool exhaustion neither counts nor resets.
    private var consecutiveErrors = 0

    /// Number of consecutive errors that engages bypass (injectable for tests).
    private let consecutiveErrorLimit: Int

    /// AC-8 latency aggregation (estimation + render, per stabilized frame).
    private var latency = StabilizationLatencyAggregator()

    /// Session-relative seconds of the bypass transition (`nil` = never bypassed).
    private var bypassAtSeconds: Double?

    /// The session anchor, stored at `start` for session-relative time conversion.
    private var anchor: HostTimeAnchor?

    // MARK: Lifecycle state

    private enum Lifecycle {
        case idle, starting, running, stopped
    }

    private var lifecycle: Lifecycle = .idle

    // MARK: Tasks

    /// Input drain: wrapped `frames` → slot. Never suspends on stage work.
    private var drainTask: Task<Void, Never>?

    /// Work loop: slot → estimate/smooth/render → own `frames`.
    private var workTask: Task<Void, Never>?

    /// Wrapped `drops` → own `drops` passthrough.
    private var dropsMergeTask: Task<Void, Never>?

    // MARK: Init

    /// Creates the decorator around a record camera source.
    ///
    /// - Parameters:
    ///   - wrapped: The record `CameraSource` (or a fake in tests).
    ///   - stabilization: Session-fixed geometry from `ResolvedCameraPlan`.
    ///   - planWidth: Planned camera width, px — the 1080p-equivalent → plan correction scale.
    ///   - stage: The estimation+render seam (live `StabilizationRenderer` in production).
    ///   - warmUpFrameCount: Warm-up length in frames (tests shrink it; default spec 60).
    ///   - consecutiveErrorLimit: Errors-in-a-row engaging bypass (default spec 60).
    ///   - overloadDetector: Bypass trigger (1) (tests inject smaller windows).
    init(
        wrapping wrapped: any VideoFrameSource & AudioSampleSource,
        stabilization: ResolvedCameraPlan.StabilizationPlan,
        planWidth: Int,
        stage: any StabilizationStage,
        warmUpFrameCount: Int = StabilizationTuning.warmUpFrameCount,
        consecutiveErrorLimit: Int = StabilizationTuning.consecutiveErrorLimit,
        overloadDetector: StabilizationOverloadDetector = StabilizationOverloadDetector()
    ) {
        self.wrapped = wrapped
        self.stabilization = stabilization
        self.planScale = Double(planWidth) / Double(StabilizationTuning.estimationReferenceWidth)
        self.stage = stage
        self.warmUp = StabilizationWarmUp(frameCount: warmUpFrameCount)
        self.consecutiveErrorLimit = consecutiveErrorLimit
        self.overloadDetector = overloadDetector

        let (frames, framesContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)
        )
        self.frames = frames
        self.framesContinuation = framesContinuation

        let (drops, dropsContinuation) = AsyncStream.makeStream(
            of: DropEvent.self,
            bufferingPolicy: .bufferingNewest(Self.dropsBufferDepth)
        )
        self.drops = drops
        self.dropsContinuation = dropsContinuation

        // Depth-1 newest-wins slot: the eager-drain policy's core (see file header).
        let (slotStream, slotContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.slotStream = slotStream
        self.slotContinuation = slotContinuation
    }

    deinit {
        // Best-effort safety net (pattern: DropMonitor.deinit) — no await in deinit. stop() is
        // the primary, ordered terminator; cancelling tasks and finishing continuations are
        // thread-safe.
        self.drainTask?.cancel()
        self.workTask?.cancel()
        self.dropsMergeTask?.cancel()
        self.slotContinuation.finish()
        self.framesContinuation.finish()
        self.dropsContinuation.finish()
    }

    // MARK: - VideoFrameSource / AudioSampleSource lifecycle

    /// Starts the stage and the wrapped camera.
    ///
    /// Teardown order contract (spec walk-through):
    /// 1. Stage resources are allocated FIRST — a throw here has no side effects to unwind and
    ///    surfaces as `RecordingError.captureSetupFailed(StabilizationError…)`, which is what
    ///    lets the start-failure alert name stabilization specifically.
    /// 2. `wrapped.start` — ITS errors propagate unchanged (a camera failure must show the
    ///    camera alert, not blame stabilization).
    /// 3. Task spawns are non-throwing. Any FUTURE fallible step added after `wrapped.start`
    ///    MUST `await wrapped.stop()` before throwing
    ///    `RecordingError.captureSetupFailed(StabilizationError…)`.
    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        guard case .idle = self.lifecycle else {
            self.logger.info("start() called in non-idle state — ignoring")
            return
        }
        self.lifecycle = .starting
        self.anchor = anchor

        do {
            try await self.stage.prepare()
        } catch {
            // No side effects yet: nothing started, nothing to stop. Terminal (one-shot).
            self.lifecycle = .stopped
            self.finishOwnStreams()
            self.logger.error("stage prepare failed: \(String(describing: error))")
            throw RecordingError.captureSetupFailed(error)
        }

        // stop() may race the awaits above (actor reentrancy, #203 pattern): if it did, unwind
        // quietly and never start the camera — stop() already finished the streams.
        guard case .starting = self.lifecycle else {
            await self.stage.finish()
            return
        }

        do {
            try await self.wrapped.start(anchoredTo: anchor)
        } catch {
            // The camera failed, not the stage: release stage resources, rethrow UNCHANGED.
            await self.stage.finish()
            self.lifecycle = .stopped
            self.finishOwnStreams()
            throw error
        }

        guard case .starting = self.lifecycle else {
            // stop() raced wrapped.start: shut the camera back down and release the stage.
            await self.wrapped.stop()
            await self.stage.finish()
            return
        }

        self.startDrainTask()
        self.startWorkTask()
        self.startDropsMergeTask()
        self.lifecycle = .running
        self.logger.info("stabilizing source started")
    }

    /// Stops the stage gracefully. Idempotent. Order (spec walk-through, pattern
    /// `VideoEncoder.stop()`): wrapped stops (its streams finish) → drain reads the input tail
    /// and finishes the slot → the in-flight work item completes (last frame reaches the
    /// output) → own streams finish → GPU resources release. No frame loss on graceful stop.
    func stop() async {
        switch self.lifecycle {
        case .stopped:
            return

        case .idle:
            self.lifecycle = .stopped
            self.slotContinuation.finish()
            self.finishOwnStreams()
            return

        case .starting, .running:
            self.lifecycle = .stopped
        }

        await self.wrapped.stop() // (1) upstream streams finish
        await self.drainTask?.value // (2) input tail drained, slot finished
        await self.workTask?.value // (3) in-flight frame delivered, work loop ended
        await self.dropsMergeTask?.value // upstream drops tail merged
        self.finishOwnStreams() // (4)
        await self.stage.finish() // (5)
        self.logger.info("stabilizing source stopped")
    }

    // MARK: - Task spawning

    /// Spawns the eager input drain: wrapped `frames` → depth-1 slot, never suspending on stage
    /// work. QoS ≥ `.userInitiated` per spec (the drain must outpace Vision spikes).
    private func startDrainTask() {
        let upstream = self.wrapped.frames
        let slot = self.slotContinuation
        self.drainTask = Task(priority: .userInitiated) { [weak self] in
            for await frame in upstream {
                guard let self else { break }
                await self.ingestIntoSlot(frame)
            }
            // Upstream finished (stop or fault): finish the slot so the work loop drains its
            // remaining item and ends on its own.
            slot.finish()
        }
    }

    /// Spawns the work loop: slot → per-frame processing on the actor (the heavy synchronous
    /// work runs on the stage's serial queue behind the continuation bridge — the actor stays
    /// responsive to the drain while a frame is in flight).
    private func startWorkTask() {
        let slot = self.slotStream
        self.workTask = Task(priority: .userInitiated) { [weak self] in
            for await frame in slot {
                guard let self else { break }
                await self.processFrame(frame)
            }
        }
    }

    /// Spawns the wrapped-drops passthrough. Upstream events keep their original attribution
    /// (capture sources never become `.stabilizeCamera`).
    private func startDropsMergeTask() {
        let upstream = self.wrapped.drops
        let sink = self.dropsContinuation
        self.dropsMergeTask = Task {
            for await event in upstream {
                sink.yield(event)
            }
        }
    }

    // MARK: - Drain side (arrivals)

    /// Ingests one arrived frame: warm-up cadence bookkeeping, slot yield with eviction
    /// detection, and the overload bypass trigger (active only after warm-up).
    private func ingestIntoSlot(_ frame: VideoFrame) {
        let ptsSeconds = CMTimeGetSeconds(frame.ptsHostTime)

        if case .warmUp = self.phase {
            // Cadence is measured on ARRIVAL pts deltas (drain side), never processing time.
            if let scale = self.warmUp.record(ptsSeconds: ptsSeconds) {
                self.warmUpMedianIntervalMs = self.warmUp.medianIntervalMs
                self.chosenEstScale = scale
                self.phase = .stabilizing(estScale: scale)
                let median = self.warmUpMedianIntervalMs.map { String(format: "%.1f", $0) } ?? "n/a"
                // Mandatory AC-8 measurement artifact: the estScale choice log.
                let choiceLine = "stabilization warm-up complete: medianIntervalMs=\(median) estScale=\(scale)"
                self.logger.notice("\(choiceLine, privacy: .public)")
            }
        }

        var evicted = false
        if case let .dropped(displaced) = self.slotContinuation.yield(frame) {
            // Newest-wins: the pending frame was displaced by a fresher one — a stage drop.
            evicted = true
            self.emitStageDrop(detectedAt: displaced.ptsHostTime)
        }

        // Bypass trigger (1) activates only AFTER warm-up completes (spec: evictions before the
        // estScale choice are not counted) and stops feeding once bypassed.
        if case .stabilizing = self.phase {
            if self.overloadDetector.record(atSeconds: ptsSeconds, evicted: evicted) {
                self.enterBypass(reason: "slot-eviction overload", detectedAt: frame.ptsHostTime)
            }
        }
    }

    // MARK: - Work side (processing)

    /// Processes one frame according to the current phase. EVERY frame is rendered — raw
    /// passthrough is forbidden (zoom-flicker; spike red flag #1).
    private func processFrame(_ frame: VideoFrame) async {
        switch self.phase {
        case .warmUp:
            // Session geometry is active from frame 1 (no zoom-flicker at warm-up exit);
            // correction stays zero. Errors here do not count — triggers arm after warm-up.
            _ = await self.renderAndDeliver(frame, correction: .zero)

        case let .stabilizing(estScale):
            await self.processStabilizing(frame, estScale: estScale)

        case .bypass:
            if self.estimationActivated {
                // Lazily release the estimation buffers on the first bypassed frame — the
                // release is serialized with any in-flight stage call by the serial work queue.
                await self.stage.deactivateEstimation()
                self.estimationActivated = false
            }
            self.lastCorrectionPlan = StabilizationSmoother.ramp(self.lastCorrectionPlan)
            _ = await self.renderAndDeliver(frame, correction: self.lastCorrectionPlan)
        }
    }

    /// The steady-state path: (lazy estimation activation) → estimate → smooth → clamp → render.
    private func processStabilizing(_ frame: VideoFrame, estScale: Int) async {
        if !self.estimationActivated {
            do {
                try await self.stage.activateEstimation(estScale: estScale)
                self.estimationActivated = true
            } catch {
                // Cannot estimate without buffers: degrade to bypass, keep recording
                // (stability over the feature). The frame still renders via the bypass path.
                self.logger.error("estimation activation failed: \(String(describing: error)) — engaging bypass")
                self.enterBypass(reason: "estimation buffer allocation failed", detectedAt: frame.ptsHostTime)
                await self.processFrame(frame)
                return
            }
        }

        let clock = ContinuousClock()
        let startInstant = clock.now
        var frameHadError = false

        do {
            if let shiftRaw = try await self.stage.estimateShift(of: frame) {
                let shiftEq = shiftRaw * (1.0 / Double(estScale))
                let correctionEq = self.smoother.ingest(shift: shiftEq)
                self.lastCorrectionPlan = self.clampToCropMargins(correctionEq * self.planScale)
            }
            // First frame after activation returns nil: no pair yet, correction stays as-is.
        } catch {
            // Estimation freeze: the smoother saw no shift (cum unchanged); the frame passes
            // through with the PREVIOUS correction. Counted toward the consecutive-error limit.
            frameHadError = true
        }

        switch await self.renderAndDeliver(frame, correction: self.lastCorrectionPlan) {
        case .delivered:
            if frameHadError {
                self.noteFrameError(detectedAt: frame.ptsHostTime)
            } else {
                self.consecutiveErrors = 0
                let millisecondsPerSecond = 1000.0
                self.latency.record(totalMs: (clock.now - startInstant).totalSeconds * millisecondsPerSecond)
            }

        case .failed:
            // Render failure joins the SHARED error streak (Vision + render).
            self.noteFrameError(detectedAt: frame.ptsHostTime)

        case .poolExhausted:
            // Downstream-congestion symptom: neither counts toward bypass nor resets the streak.
            break
        }
    }

    /// One render+deliver outcome.
    private enum RenderOutcome {
        /// The stabilized frame reached the output stream.
        case delivered
        /// The output pool refused allocation (threshold) — frame dropped, no bypass signal.
        case poolExhausted
        /// The render itself failed — frame dropped, counts toward the error streak.
        case failed
    }

    /// Renders `frame` with `correction` and yields the result to the output stream, emitting
    /// the appropriate drop events for every failure mode.
    private func renderAndDeliver(_ frame: VideoFrame, correction: StabilizationVector) async -> RenderOutcome {
        do {
            let rendered = try await self.stage.render(frame, correction: correction)
            if case let .dropped(displaced) = self.framesContinuation.yield(rendered) {
                // Output overflow = slow encoder downstream: REAL content loss, ordinary
                // encoder backpressure with the stage as the detecting source.
                self.dropsContinuation.yield(DropEvent(
                    reason: .encoderBackpressureDrops,
                    source: .stabilizeCamera,
                    count: 1,
                    detectedAt: displaced.ptsHostTime
                ))
            }
            return .delivered
        } catch StabilizationStageError.outputPoolExhausted {
            self.emitStageDrop(detectedAt: frame.ptsHostTime)
            return .poolExhausted
        } catch {
            // Raw passthrough is forbidden even on a render failure (geometry) — the tick is
            // refilled downstream by the CFR hold-repeat.
            self.logger.error("render failed: \(String(describing: error))")
            self.emitStageDrop(detectedAt: frame.ptsHostTime)
            return .failed
        }
    }

    // MARK: - Bypass & errors

    /// Registers one estimation/render error; the shared streak engages bypass at the limit.
    private func noteFrameError(detectedAt: CMTime) {
        self.consecutiveErrors += 1
        if self.consecutiveErrors >= self.consecutiveErrorLimit {
            self.enterBypass(reason: "\(self.consecutiveErrors) consecutive stage errors", detectedAt: detectedAt)
        }
    }

    /// Engages bypass: estimation stops (released lazily by the work task), the session-fixed
    /// geometry keeps rendering, the correction ramps to zero. One-way within a session.
    private func enterBypass(reason: String, detectedAt: CMTime) {
        guard self.bypassAtSeconds == nil else { return }
        let seconds = self.sessionSeconds(of: detectedAt)
        self.bypassAtSeconds = seconds
        self.phase = .bypass
        let secondsDescription = String(format: "%.1f", seconds)
        self.logger.warning(
            "stabilization bypass engaged at \(secondsDescription, privacy: .public)s: \(reason, privacy: .public)"
        )
    }

    // MARK: - Helpers

    /// Clamps a plan-pixel correction to the crop margins per axis — a single large shift (the
    /// camera was bumped) must not expose the `clampToExtent` edge smear for the tens of seconds
    /// the reference needs to crawl back (0.6 px/s).
    private func clampToCropMargins(_ correction: StabilizationVector) -> StabilizationVector {
        let marginX = Double(self.stabilization.cropRect.minX)
        let marginY = Double(self.stabilization.cropRect.minY)
        return StabilizationVector(
            dx: min(max(correction.dx, -marginX), marginX),
            dy: min(max(correction.dy, -marginY), marginY)
        )
    }

    /// Converts an absolute host-time PTS into session-relative seconds via the stored anchor.
    private func sessionSeconds(of pts: CMTime) -> Double {
        guard let anchor = self.anchor else { return CMTimeGetSeconds(pts) }
        return CMTimeGetSeconds(PipelineClock.convert(hostTime: pts, anchoredTo: anchor))
    }

    /// Emits one stage-internal drop (`.stabilizeCamera` / `.stabilizationDrops`).
    private func emitStageDrop(detectedAt: CMTime) {
        self.dropsContinuation.yield(DropEvent(
            reason: .stabilizationDrops,
            source: .stabilizeCamera,
            count: 1,
            detectedAt: detectedAt
        ))
    }

    /// Finishes the decorator's own streams (frames + merged drops). Idempotent.
    private func finishOwnStreams() {
        self.framesContinuation.finish()
        self.dropsContinuation.finish()
    }
}

// MARK: - StabilizationDiagnosticsProviding

extension StabilizingVideoSource: StabilizationDiagnosticsProviding {
    /// End-of-session stage diagnostics for the technical report (AC-4/AC-8). Call after
    /// `stop()` — the work loop has ended, so the values are final.
    func stabilizationDiagnostics() -> StabilizationDiagnostics {
        StabilizationDiagnostics(
            latencyLine: self.latency.reportLine(
                estScale: self.chosenEstScale,
                warmUpMedianIntervalMs: self.warmUpMedianIntervalMs
            ),
            bypassAtSeconds: self.bypassAtSeconds
        )
    }
}
