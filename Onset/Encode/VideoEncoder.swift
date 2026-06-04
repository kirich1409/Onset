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

// MARK: - VideoEncoder

/// A single-stream hardware HEVC encoder.
///
/// One instance encodes exactly one stream (screen OR camera). Frames enter via `ingest`;
/// the CFR clock (`tick`) fills slot gaps with holds; encoded HEVC samples leave on
/// `encodedSamples`; drops are reported on `drops`.
///
/// ### Constant-frame-rate driving (spec §CFR, OpAC-4.2/4.3)
/// The actor delegates every slot decision to `CFRNormalizer`. `ingest` feeds the frame's
/// PTS-in-seconds; `tick(slotIndex:)` (wall-clock timer, or tests synchronously) fills a gap
/// with a hold that re-submits the last `CVPixelBuffer`.
///
/// ### Anchored PTS (Decision #3 — critical)
/// The PTS handed to `encodeFrame` is the ABSOLUTE host-time value built with exact integer
/// CMTime math from the normalizer's integer `slotIndex` — see `anchoredPTS(slotIndex:)`.
actor VideoEncoder {
    // MARK: - Types

    /// Builds a configured `CompressionSession` for `width × height` with `settings`,
    /// wiring the output to `sink`. Throws `VideoEncoderError.hardwareEncoderUnavailable`
    /// when a HW HEVC session cannot be created (no software fallback). Property-set
    /// failures other than the DataRateLimits fallback surface via the actor as
    /// `RecordingError.encoderSetupFailed`.
    typealias SessionFactory = @Sendable (
        _ width: Int32,
        _ height: Int32,
        _ sink: EncodedSampleSink
    ) throws -> any CompressionSession

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

    // `internal` (not `private`): the VideoEncoder+Configuration.swift extension uses it.
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

    /// The standalone CFR clock loop spawned by `start()` and cancelled by `stop()`.
    /// Drives `clockTick()` at `1/fps`. Replaced by #34's shared clock once it exists.
    private var clockTickTask: Task<Void, Never>?

    // MARK: - Output streams

    /// Encoded HEVC samples, in decode order, fed by the C output callback via the sink.
    nonisolated let encodedSamples: AsyncStream<EncodedSample>
    private let encodedSamplesContinuation: AsyncStream<EncodedSample>.Continuation

    /// Drop events for `DropMonitor` (#35). One `DropEvent` per backpressure drop.
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
    ///   - selfClocked: Whether `start()` spawns the standalone CFR clock. `true` (default) for
    ///     standalone use; `false` when an external coordinator (#34) or a test drives
    ///     `clockTick()`.
    ///   - sessionFactory: Injectable seam. Defaults to the live VideoToolbox implementation;
    ///     tests inject a mock.
    init(
        settings: VTEncoderSettings,
        width: Int32,
        height: Int32,
        fps: Int,
        anchor: HostTimeAnchor = .now(),
        maxPendingFrames: Int = 4,
        selfClocked: Bool = true,
        sessionFactory: @escaping SessionFactory = VideoEncoder.liveSessionFactory
    ) {
        precondition(fps > 0, "fps must be positive")
        precondition(width > 0 && height > 0, "dimensions must be positive")

        self.settings = settings
        self.width = width
        self.height = height
        self.fps = fps
        self.anchor = anchor
        self.maxPendingFrames = maxPendingFrames
        self.selfClocked = selfClocked
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
    var cfrNormalizationDropCount: Int { self.normalizer.cfrNormalizationDrops }

    /// Encoder-backpressure drop count (`DropReason.encoderBackpressureDrops`). Separate
    /// from `cfrNormalizationDropCount`.
    var backpressureDropCount: Int { self.encoderBackpressureDrops }

    /// Whether the active session uses a hardware encoder (false when not started).
    /// Drives the L5 HW assertion.
    var isUsingHardwareEncoder: Bool { self.session?.usingHardwareEncoder() ?? false }

    // MARK: - Lifecycle

    /// Creates and configures the compression session.
    ///
    /// - Throws: `RecordingError.noHardwareEncoder` when no HW HEVC encoder is available
    ///   (the factory threw); `RecordingError.encoderSetupFailed` when a mandatory property
    ///   could not be set.
    func start() throws {
        guard self.session == nil else { return }

        let sink = EncodedSampleSink(continuation: self.encodedSamplesContinuation)
        let session: any CompressionSession
        do {
            session = try self.sessionFactory(self.width, self.height, sink)
        } catch {
            // No software fallback (AC-6 / OpAC-4.1).
            self.logger.error("Hardware HEVC session creation failed — no software fallback")
            throw RecordingError.noHardwareEncoder
        }

        do {
            try self.configure(session: session)
        } catch {
            session.invalidate()
            throw error
        }

        self.session = session
        self.sink = sink
        if self.selfClocked {
            self.startClock()
        }
        self.logger.info("VideoEncoder started — \(self.width)×\(self.height)@\(self.fps)fps")
    }

    /// Stops the encoder: cancels the CFR clock, drains in-flight frames, tears down the
    /// session, then finishes the output streams.
    ///
    /// Teardown order is load-bearing: the clock task is cancelled AND awaited first so no
    /// tick races teardown; then `completeFrames()` blocks until all in-flight output
    /// callbacks have fired; then `invalidate()` guarantees no further callbacks; and only
    /// THEN are the continuations finished — so no callback ever yields into a finished
    /// continuation.
    func stop() async {
        guard let session = self.session else { return }
        self.clockTickTask?.cancel()
        await self.clockTickTask?.value
        self.clockTickTask = nil
        session.completeFrames()
        session.invalidate()
        self.session = nil
        self.sink = nil
        self.lastPixelBuffer = nil
        self.encodedSamplesContinuation.finish()
        self.dropsContinuation.finish()
    }

    // MARK: - CFR clock

    /// Spawns the standalone CFR clock loop.
    ///
    /// The loop sleeps `1/fps` and calls `clockTick()` until cancelled. This is the
    /// production driver that makes holds (OpAC-4.2) actually fire. Once `RecordingSession`
    /// (#34) exists it owns both the source subscription and the clock and will drive
    /// `clockTick()` itself; until then this self-clock keeps the unit functional standalone.
    private func startClock() {
        let nanosPerSecond = 1_000_000_000
        let nanosPerTick = UInt64(nanosPerSecond / self.fps)
        self.clockTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanosPerTick)
                if Task.isCancelled { return }
                // A deallocated-but-unstopped encoder ends the loop rather than spinning.
                guard let self else { return }
                await self.clockTick()
            }
        }
    }

    /// One wall-clock CFR tick: hold the current grid slot if it is still empty.
    ///
    /// Reads the present host time, computes the current grid slot, and fires the hold path
    /// ONLY when that slot is ahead of the last emitted slot. An already-filled slot is a
    /// silent no-op — it never reaches `CFRNormalizer.processTick`'s defensive drop branch,
    /// so the standalone clock cannot corrupt `cfrNormalizationDrops`. The read-and-decide is
    /// atomic: it is synchronous actor-isolated code with no `await` between the slot read and
    /// the tick.
    ///
    /// Known limitation (accepted for the standalone clock): a tick may fire slot N before
    /// N's real frame arrives, then `ingest` drops that frame as a duplicate. #34, owning both
    /// the source and the clock, refines the phase. Not handled here by design.
    func clockTick() {
        guard self.lastPixelBuffer != nil else { return }
        let nowSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime())
        let anchorSeconds = CMTimeGetSeconds(self.anchor.anchorTime)
        let currentSlot = Int(((nowSeconds - anchorSeconds) * Double(self.fps)).rounded(.down))
        guard currentSlot > self.normalizer.lastEmittedSlot else { return }
        self.tick(slotIndex: currentSlot)
    }

    // MARK: - Ingest (new frame)

    /// Ingests a new captured frame.
    ///
    /// Drives the CFR normalizer with the frame's PTS-in-seconds. On `.encode` the absolute
    /// anchored PTS is built from the integer slot index and the frame is submitted (subject
    /// to the backpressure gate). On `.drop(.cfrNormalizationDrops)` the duplicate-slot frame
    /// is dropped — `cfrNormalizationDrops` is owned by the normalizer; `encoderBackpressureDrops`
    /// is NOT touched.
    ///
    /// Input frames always arrive with `isHoldRepeat == false`; this encoder owns the hold
    /// decision via the normalizer.
    func ingest(_ frame: VideoFrame) {
        let ptsSeconds = CMTimeGetSeconds(frame.ptsHostTime)
        let anchorSeconds = CMTimeGetSeconds(self.anchor.anchorTime)
        let decision = self.normalizer.processFrame(
            ptsSeconds: ptsSeconds,
            anchorSeconds: anchorSeconds,
            fps: self.fps
        )

        switch decision {
        case let .encode(slotIndex, _, _):
            self.lastPixelBuffer = frame.pixelBuffer
            self.submit(pixelBuffer: frame.pixelBuffer, slotIndex: slotIndex, detectedAt: frame.ptsHostTime)

        case .drop:
            // .cfrNormalizationDrops and .preAnchor are accounted inside the normalizer;
            // no backpressure counter is touched here.
            break
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
            self.logger.error("VTCompressionSessionEncodeFrame failed: \(status) at slot \(slotIndex)")
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
