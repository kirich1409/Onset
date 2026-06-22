import CoreMedia
import OSLog

// type_body_length / file_length are disabled file-wide: the start sequence, per-pipeline
// construction, the AC-12 event loop, and the AC-9 stop order are one cohesive orchestration sharing
// the pipeline / stage / monitor state; splitting across extensions would scatter the load-bearing
// ordering for no readability gain (same rationale `FileWriter` documents for its `file_length`).
// swiftlint:disable type_body_length file_length

// MARK: - RecordingSession

/// Orchestrates the two-file recording pipeline (#34): owns the single host-time epoch, builds the
/// sources + encoders per the resolved start plan, wires the routing, drives the source-event loop
/// (AC-12), feeds the `DropMonitor`, and finalises both files on stop (AC-9).
///
/// ### The single T0 epoch (AC-7)
/// `start()` captures `anchor = HostTimeAnchor.now()` ONCE at the very beginning. `T0 =
/// anchor.anchorTime`. The SAME `anchor` is passed to BOTH encoders and BOTH sources
/// (`source.start(anchoredTo: anchor)`), and `T0` is passed to `DualFileOutputStage`, whose writers
/// all call `startSession(atSourceTime: T0)`. No pipeline ever uses `.zero` or a first-sample PTS.
///
/// ### Clock driving — deliberate deviation
/// Each `VideoEncoder` is `selfClocked: true` and drives its OWN CFR grid off the shared anchor.
/// `RecordingSession` owns only T0 — it does NOT drive `clockTick()`. This is a deliberate deviation
/// from any earlier stub comment that said "RecordingSession drives clockTick": screen and camera
/// are independent CFR grids on different fps, and one driver cannot serve both. AC-7 is satisfied by
/// the shared T0 epoch + host-rooted PTS, NOT by a shared tick. (In tests the encoder fakes emit
/// samples directly rather than via `clockTick()`.)
///
/// ### Concurrency
/// `actor`. Routing runs as stored per-pipeline `Task` handles (NOT an inline `withTaskGroup`):
/// `start()` must return once capture is live, and AC-12 must tear down ONE pipeline while the other
/// runs — both impossible with an inline-awaited group. The stored handles are joined in the
/// load-bearing stop order.
actor RecordingSession {
    // MARK: - Logger

    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "RecordingSession"
    )

    // MARK: - State stream (UI surface — #36/#37)

    /// Backpressure-health transitions for the UI (`RecordingState.normal ↔ .degraded`).
    ///
    /// Created at `init` (with the stored `stateContinuation`) so a subscriber can iterate it
    /// immediately, before `start()` builds the `DropMonitor`. `start()` spins a forwarding task
    /// that pipes the monitor's own `state` stream into this continuation; `performStop()` /
    /// `teardownAfterFailedStart()` finish the continuation, ending the subscriber's loop.
    ///
    /// **Single-consumer.** Exactly ONE subscriber (the `RecordingCoordinator`) may iterate this
    /// stream. `AsyncStream` splits elements across iterators rather than duplicating them, so a
    /// second consumer would starve the first. Menu bar and recording window read live state from
    /// the coordinator's `@Observable` properties — they do NOT subscribe here. Emits only on a
    /// `.normal ↔ .degraded` transition (no initial `.normal`), matching `DropMonitor.state`.
    nonisolated let recordingStateStream: AsyncStream<RecordingState>
    private let stateContinuation: AsyncStream<RecordingState>.Continuation

    // MARK: - Capture-active stream (UI gate — #171)

    /// Screen-capture activation signal: yields once when the first real screen frame arrives,
    /// then finishes. See `RecordingControlling.captureActiveStream` for the full contract.
    ///
    /// Created at `init` so the coordinator can subscribe before `start()` is called. Finished
    /// in BOTH `performStop()` and `teardownAfterFailedStart()` so a subscriber never hangs.
    nonisolated let captureActiveStream: AsyncStream<Void>
    private let captureActiveContinuation: AsyncStream<Void>.Continuation

    // MARK: - Revocation stream (UI surface — #39 / AC-12)

    /// Graceful-revocation notifications for the UI (`RecordingRevocation`).
    ///
    /// `handleSourceEvent` already finalises the affected pipeline on `.displayDisconnected` /
    /// `.cameraDisconnected` (the Epic-3 behaviour, unchanged). AFTER finalising, it yields here so
    /// the `RecordingCoordinator` can update the recording window's per-source liveness, and — when
    /// the last video pipeline is gone — receives `.allVideoSourcesLost` and ends the session.
    ///
    /// Created at `init` (with the stored `revocationContinuation`) so the coordinator can iterate it
    /// from `start()`, before any revoke can fire. The session yields DIRECTLY from
    /// `handleSourceEvent` (already on the actor) — no forwarding task. `performStop()` /
    /// `teardownAfterFailedStart()` finish the continuation, ending the subscriber's loop (same
    /// lifecycle as `recordingStateStream`).
    ///
    /// **Single-consumer.** Exactly ONE subscriber (the `RecordingCoordinator`) — see
    /// `RecordingRevocation`. `AsyncStream` splits elements across iterators, so a second consumer
    /// would starve the first.
    nonisolated let sourceRevocationStream: AsyncStream<RecordingRevocation>
    private let revocationContinuation: AsyncStream<RecordingRevocation>.Continuation

    /// Pipes `dropMonitor.state` → `stateContinuation`. Spun in `start()` (the monitor only exists
    /// then) and torn down in `performStop()` / `teardownAfterFailedStart()`. Captures the monitor's
    /// stream value + the continuation — never `self` — so it does not retain the session actor.
    private var stateForwardingTask: Task<Void, Never>?

    // MARK: - Inputs

    private var plan: ResolvedRecordingPlan
    private let display: Display
    private let cameraDevice: CameraDevice?
    private let cameraFormat: CameraFormat?
    private let micDevice: MicrophoneDevice?
    private let config: RecordingConfiguration

    // MARK: - Session directory

    /// The session-scoped subdirectory where both output files are written.
    ///
    /// Computed once in `init` from `config.baseOutputDirectory` + session-start timestamp so
    /// both pipelines share the same parent directory. Unique-collision-avoidance (` (N)` suffix)
    /// is applied at the **directory** level here; individual file names inside are stable.
    /// The directory is created lazily in `start()` after capability checks pass.
    ///
    /// `nonisolated` because `URL` is a value type and the property is set once in `init`.
    nonisolated let sessionDirectory: URL

    /// Session-start timestamp shared by both output files and the technical report file name.
    ///
    /// Captured once in `init` (the same `Date` used to derive `sessionDirectory` and the file
    /// names), so the report header and file name match the recording files. `nonisolated` because
    /// `Date` is a value type set once in `init`.
    nonisolated let sessionStartDate: Date

    // MARK: - Seams

    private let probe: @Sendable () -> ProbeResult
    private let encoderFactory: any EncoderFactory
    private let writerFactory: any WriterFactory
    private let sourceFactory: any SourceFactory

    // MARK: - Per-pipeline runtime state

    /// A running video pipeline: its source, encoder, kind, and the two routing task handles.
    private struct Pipeline {
        let kind: RecordingPipelineKind
        let source: any VideoFrameSource
        let encoder: any EncoderControlling
        /// frames → `encoder.ingest`. Joined BEFORE `encoder.stop()` so the encoder flushes the tail.
        var framesTask: Task<Void, Never>
        /// `encoder.encodedSamples` → `stage.routeVideo`. Joined AFTER `encoder.stop()`.
        var routeVideoTask: Task<Void, Never>
    }

    private var screenPipeline: Pipeline?
    private var cameraPipeline: Pipeline?

    /// The camera's mic-audio routing task (`audioSamples` → `stage.routeAudio`). Lives on the
    /// camera lifecycle: when the camera stops, the mic stream ends and this task exits, which is
    /// what ends screen-file audio (AC-12) — there is no track-granular writer API.
    private var audioTask: Task<Void, Never>?

    /// The merged source-event loop (AC-12 revoke handling).
    private var eventLoopTask: Task<Void, Never>?

    private var stage: DualFileOutputStage?
    private var dropMonitor: DropMonitor?

    /// Lifecycle of the session.
    ///
    /// Replaces the `hasStarted: Bool` flag with an exhaustive enum so the compiler enforces
    /// that `start()` transitions are handled and the one-shot invariant is visible at the type
    /// level. `stopTask` is kept as a SEPARATE stored var — the memoization assign is
    /// concurrency-load-bearing and must not be folded into the enum.
    private enum SessionState {
        /// Initial state: `start()` has not been called.
        case idle
        /// `start()` has been called (whether or not it threw — a throwing start is terminal).
        case running
        /// `stop()` has been called and teardown is in progress or complete.
        case stopped
    }

    private var sessionState: SessionState = .idle
    private var stopTask: Task<RecordingResult, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - plan: The resolved capture plan (screen dimensions + optional camera plan).
    ///   - display: The selected display.
    ///   - cameraDevice / cameraFormat: The selected camera + its format, or `nil` (no camera).
    ///   - micDevice: The selected microphone, or `nil` (no audio).
    ///   - config: Recording policy.
    ///   - probe: Capability pre-flight (AC-6). Defaults to the live `CapabilityProbe`.
    ///   - encoderFactory / writerFactory / sourceFactory: DI seams (live by default).
    init(
        plan: ResolvedRecordingPlan,
        display: Display,
        cameraDevice: CameraDevice?,
        cameraFormat: CameraFormat?,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration,
        probe: (@Sendable () -> ProbeResult)? = nil,
        encoderFactory: any EncoderFactory = LiveEncoderFactory(),
        writerFactory: (any WriterFactory)? = nil,
        sourceFactory: any SourceFactory = LiveSourceFactory()
    ) {
        self.plan = plan
        self.display = display
        self.cameraDevice = cameraDevice
        self.cameraFormat = cameraFormat
        self.micDevice = micDevice
        self.config = config
        self.encoderFactory = encoderFactory
        self.sourceFactory = sourceFactory

        // Capture the session-start timestamp once. Both URL providers below close over this
        // value so screen and camera files always share an identical timestamp segment (#198).
        let startDate = Date()
        self.sessionStartDate = startDate

        // Compute the session subdirectory from the base output directory and the start timestamp.
        // Collision avoidance (` (N)` suffix) is applied at the directory level so both files
        // inside the folder carry stable, unsuffixed names (#225).
        let sessionDir = OutputDirectoryNaming.uniqueSessionDirectory(
            in: config.baseOutputDirectory,
            timestamp: startDate
        )
        self.sessionDirectory = sessionDir

        // UI state stream + its continuation, created here so a subscriber can iterate before
        // start() builds the DropMonitor whose transitions are forwarded into this continuation.
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: RecordingState.self)
        self.recordingStateStream = stateStream
        self.stateContinuation = stateContinuation

        // Revocation stream + its continuation (AC-12 UI seam), created here so the coordinator can
        // iterate from start() before any revoke fires. Yielded directly from handleSourceEvent.
        let (revocationStream, revocationContinuation) = AsyncStream.makeStream(of: RecordingRevocation.self)
        self.sourceRevocationStream = revocationStream
        self.revocationContinuation = revocationContinuation

        // Capture-active stream + its continuation (#171 UI gate), created here so the coordinator
        // can subscribe before start() is called. Yields once on first real screen frame, then
        // finishes. Finished in both performStop() and teardownAfterFailedStart() so subscribers
        // never hang regardless of how the session ends.
        // Relies on the DEFAULT .unbounded buffering: a yield that fires before the coordinator
        // subscribes is retained in the buffer. A .bufferingNewest/Oldest(1) policy would silently
        // drop it and leave the coordinator hanging until the 30 s timeout.
        let (captureActiveStream, captureActiveContinuation) = AsyncStream.makeStream(of: Void.self)
        self.captureActiveStream = captureActiveStream
        self.captureActiveContinuation = captureActiveContinuation

        // Default live probe: classify against the resolved display + camera format.
        self.probe = probe ?? { CapabilityProbe.probe(display: display, cameraFormat: cameraFormat, config: config) }

        // Default live writer factory: place both files in the session subdirectory (#225).
        // Both kinds close over `startDate` and `sessionDir` — not a fresh Date() / new URL per
        // call — so the pair of files for one session shares the same timestamp and parent folder.
        self.writerFactory = writerFactory ?? LiveWriterFactory(configuration: config) { kind in
            let fileKind: RecordingFileKind = switch kind {
            case .screen: .screen
            case .camera: .camera
            }
            return RecordingOutput.uniqueOutputURL(in: sessionDir, timestamp: startDate, kind: fileKind)
        }
    }

    // MARK: - Start

    /// Starts the recording session.
    ///
    /// Sequence (see type doc + spec §"Единая эпоха старта"):
    /// 1. `CapabilityProbe` (AC-6): `.noHardwareEncoder` → throw, no start.
    ///    `.budgetExceeded(suggested:)` → adopt the reduced profile and continue (AC-5).
    /// 2. Resolve the start plan from permissions + device presence (AC-11) → throw on no video.
    /// 3. Capture the single anchor / T0.
    /// 4. Build `DualFileOutputStage` (writers created lazily on first sample).
    /// 5. Build encoders (`selfClocked: true`, shared anchor) + sources per plan; start encoders
    ///    (AC-6 can also surface here).
    /// 6. Spin up routing tasks + DropMonitor; forward state.
    /// 7. Start the sources (anchored to the shared anchor).
    ///
    /// - Parameter permissions: The effective permissions at start time (AC-11 gating).
    /// - Throws: `RecordingError` (`.noHardwareEncoder`, `.noVideoSource`, or an encoder/setup
    ///   error). On any throw nothing is left running and no writers are created.
    func start(permissions: EffectivePermissions) async throws {
        // Exhaustive switch — intentional: a future SessionState case addition must be handled here.
        switch self.sessionState {
        case .idle:
            break // proceed to start

        case .running, .stopped:
            preconditionFailure("RecordingSession.start() is one-shot")
        }
        // Set state BEFORE the first throwing call so that a throwing start leaves the session in
        // `.running` — preventing a second start() attempt on an already-broken session.
        self.sessionState = .running

        try self.runCapabilityPreflight() // 1. AC-6
        let startPlan = try self.resolvePlan(permissions: permissions) // 2. AC-11

        // Create the session subdirectory before any FileWriter is constructed (#225).
        // Placed after resolvePlan so the directory is only created when recording will
        // actually proceed, and before the T0 anchor capture so filesystem I/O does not
        // perturb the timing-critical window.
        // The directory name (not its full path) is safe to log — it contains only the
        // session timestamp, never the user's home path (issue #188).
        do {
            try RecordingOutput.ensureDirectory(self.sessionDirectory)
            self.logger.info(
                "Session directory created: \(self.sessionDirectory.lastPathComponent)"
            )
        } catch {
            self.logger.error(
                "Session directory unavailable: \(self.sessionDirectory.lastPathComponent) — \(error)"
            )
            throw RecordingError.outputDirectoryUnavailable(error)
        }

        // 3. The single T0 epoch (AC-7). Captured ONCE, here, before anything else runs.
        let anchor = HostTimeAnchor.now()
        let stage = self.makeStage(startPlan: startPlan, sessionT0: anchor.anchorTime) // 4.
        self.startStateForwarding() // forward dropMonitor.state → recordingStateStream (UI).

        // 5-7. Build pipelines, wire the event loop, start the sources. Any throw tears down.
        do {
            try await self.buildPipelines(startPlan: startPlan, anchor: anchor, stage: stage)
            self.startEventLoop() // 6. AC-12 event loop; DropMonitor.observe done in build steps.
            try await self.startSources(anchor: anchor) // 7. Frames flow → encoders → routeVideo.
        } catch {
            // Tear down anything already running so a partial start leaves nothing live.
            await self.teardownAfterFailedStart()
            throw error
        }

        let scr = startPlan.includeScreen
        let cam = startPlan.includeCamera
        self.logger.info("RecordingSession started — screen=\(scr) camera=\(cam) audio=\(startPlan.includeAudio)")
    }

    // MARK: - Start helpers

    /// Capability pre-flight (AC-6/AC-5): throws on the no-HW path; adopts the reduced profile
    /// on `.budgetExceeded` (AC-5: start with the suggested plan rather than aborting).
    private func runCapabilityPreflight() throws {
        switch self.probe() {
        case .ok:
            break

        case .noHardwareEncoder:
            self.logger.error("CapabilityProbe: no hardware HEVC encoder — start blocked (AC-6)")
            throw RecordingError.noHardwareEncoder

        case let .budgetExceeded(suggested):
            // AC-5: budget was exceeded; the probe resolved a reduced profile that fits within the
            // budget. Adopt it and continue — do NOT abort. The caller observes the reduced
            // dimensions via the session's output files.
            self.logger.warning("CapabilityProbe: budget exceeded — starting with reduced profile (AC-5)")
            self.plan = suggested
        }
    }

    /// Resolves which pipelines run (AC-11); throws `.noVideoSource` when neither is possible.
    private func resolvePlan(permissions: EffectivePermissions) throws -> RecordingStartPlan {
        let resolution = resolveStartPlan(
            permissions: permissions,
            screenDevicePresent: true, // a Display was resolved by the caller
            cameraDevicePresent: self.cameraDevice != nil && self.cameraFormat != nil,
            micDevicePresent: self.micDevice != nil
        )
        switch resolution {
        case let .success(plan):
            return plan

        case let .failure(error):
            self.logger.error("resolveStartPlan failed: \(String(describing: error)) — start blocked (AC-11)")
            throw error
        }
    }

    /// Builds the `DropMonitor` + `DualFileOutputStage` (writers created lazily on first sample).
    private func makeStage(startPlan: RecordingStartPlan, sessionT0: CMTime) -> DualFileOutputStage {
        var expectedKinds: Set<RecordingPipelineKind> = []
        if startPlan.includeScreen { expectedKinds.insert(.screen) }
        if startPlan.includeCamera { expectedKinds.insert(.camera) }

        let monitor = DropMonitor(
            windowSeconds: self.config.degradedWindowSeconds,
            threshold: self.config.degradedBackpressureThreshold
        )
        self.dropMonitor = monitor

        let stage = DualFileOutputStage(
            sessionT0: sessionT0,
            expectedPipelines: expectedKinds,
            includeAudio: startPlan.includeAudio,
            writerFactory: self.writerFactory,
            onWriterCreated: { [weak monitor] writer in
                // Register each lazily-created writer's backpressure channel (AC-8/AC-9).
                await monitor?.observe(writer.drops)
            },
            onAllWritersFaulted: { [weak self] in
                // All writers have faulted mid-recording — stop immediately so the user gets
                // the write-failure alert without having to press Stop (#105 fail-fast).
                // `stop()` is idempotent via its memoised `stopTask`.
                _ = await self?.stop()
            },
            onWriterFaulted: { [weak self] kind in
                // One writer faulted while the other pipeline is still live — stop the faulted
                // pipeline and flip its liveness in the recording window (#197 live UI seam).
                await self?.handleWriterFault(kind)
            }
        )
        self.stage = stage
        return stage
    }

    /// Builds + starts the encoders and sources per the start plan. Encoder start can surface AC-6.
    private func buildPipelines(
        startPlan: RecordingStartPlan,
        anchor: HostTimeAnchor,
        stage: DualFileOutputStage
    ) async throws {
        guard let monitor = self.dropMonitor else { return }
        if startPlan.includeScreen {
            try await self.buildScreenPipeline(anchor: anchor, stage: stage, monitor: monitor)
        }
        if startPlan.includeCamera {
            try await self.buildCameraPipeline(
                anchor: anchor,
                stage: stage,
                monitor: monitor,
                includeAudio: startPlan.includeAudio
            )
        }
    }

    /// Starts the sources, anchored to the shared anchor (frames with host-time < T0 are dropped
    /// by the sources' existing gate).
    ///
    /// When a screen pipeline is present, the first real screen frame triggers `captureActiveStream`
    /// (#171 — `SCStream.startCapture()` returns before consent on macOS 26). When there is NO
    /// screen pipeline (camera-only), the stream is yielded immediately after sources start because
    /// there is no consent gate to wait for.
    private func startSources(anchor: HostTimeAnchor) async throws {
        if let screen = self.screenPipeline {
            try await screen.source.start(anchoredTo: anchor)
        }
        if let camera = self.cameraPipeline {
            try await camera.source.start(anchoredTo: anchor)
        }
        // Camera-only path: no screen pipeline means no first-frame hook will fire. Signal the
        // coordinator immediately so the UI is not gated on a frame that will never come.
        if self.screenPipeline == nil {
            self.captureActiveContinuation.yield(())
            self.captureActiveContinuation.finish()
        }
    }

    /// Spins the forwarding task that pipes `dropMonitor.state` → `recordingStateStream`. Captures
    /// the monitor's stream value + the stored continuation only (never `self`), so the task does
    /// not retain the session actor. The loop ends when the monitor finishes its `state` stream
    /// (in `DropMonitor.stop()`) or when `performStop()` cancels this task — whichever comes first.
    private func startStateForwarding() {
        guard let monitorState = self.dropMonitor?.state else { return }
        let continuation = self.stateContinuation
        self.stateForwardingTask = Task {
            for await state in monitorState {
                continuation.yield(state)
            }
        }
    }

    // MARK: - UI state surface (#36/#37)

    /// The session's current drop health snapshot, polled ~1 Hz by the UI (`RecordingCoordinator`)
    /// to keep `RecordingCoordinator.drops` current during recording. Returns a zero / never-degraded
    /// snapshot before `start()` builds the monitor or after `performStop()` tears it down.
    func currentDrops() async -> DropHealthSnapshot {
        await self.dropMonitor?.snapshot()
            ?? DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
    }

    /// The camera lane's latest rate snapshot, polled ~1 Hz by the coordinator (Phase C) to feed
    /// `FpsCollapseDetector` (critical-recording-signals, T-B.2). Parallels `currentDrops()`: a
    /// pure on-demand PULL, no stream / subscriber. Reads the source's own `captureRateLock` via the
    /// `nonisolated currentRateSnapshot()` accessor — no second lock, no actor hop on the source.
    ///
    /// Returns `nil` before the first camera flush, when there is no camera pipeline (screen-only),
    /// or after teardown. Only the camera lane is plumbed — encoder/writer snapshots feed no detector
    /// (spec §Architecture). The snapshot's freshness stamp is seconds-since-session-T0 (the same
    /// frame as the detector's tick clock), so the coordinator passes it straight in as
    /// `FpsCollapseSample.sampleElapsedSeconds` to discard a frozen-camera reading.
    func currentRates() -> CameraRateSnapshot? {
        self.cameraPipeline?.source.currentRateSnapshot()
    }

    // MARK: - Pipeline construction

    private func buildScreenPipeline(
        anchor: HostTimeAnchor,
        stage: DualFileOutputStage,
        monitor: DropMonitor
    ) async throws {
        let source = self.sourceFactory.makeScreenSource(plan: self.plan, config: self.config)
        let encoder = self.encoderFactory.makeEncoder(
            kind: .screen,
            plan: self.plan,
            config: self.config,
            anchor: anchor
        )
        try await encoder.start()

        await monitor.observe(source.drops)
        await monitor.observe(encoder.drops)

        // Capture the continuation (not self) in the first-frame hook so the task does not
        // retain the session actor. Yield once + finish immediately: the coordinator only
        // needs the "first real frame arrived" signal, extra yields are not consumed.
        let captureActiveContinuation = self.captureActiveContinuation
        let framesTask = Self.makeFramesTask(
            source: source,
            encoder: encoder,
            onFirstFrame: {
                captureActiveContinuation.yield(())
                captureActiveContinuation.finish()
            },
            // Fix #1: when the frames stream ends without a first frame (consent denied or
            // terminal stop), finish the continuation so awaitCaptureActivation returns
            // promptly rather than waiting the full 30-second timeout.
            onEndWithoutFirstFrame: {
                captureActiveContinuation.finish()
            }
        )
        let routeVideoTask = Self.makeRouteVideoTask(encoder: encoder, kind: .screen, stage: stage)

        self.screenPipeline = Pipeline(
            kind: .screen,
            source: source,
            encoder: encoder,
            framesTask: framesTask,
            routeVideoTask: routeVideoTask
        )
    }

    private func buildCameraPipeline(
        anchor: HostTimeAnchor,
        stage: DualFileOutputStage,
        monitor: DropMonitor,
        includeAudio: Bool
    ) async throws {
        guard let cameraDevice = self.cameraDevice, let cameraFormat = self.cameraFormat else {
            // Should not happen: includeCamera implies the device was present.
            throw RecordingError.noVideoSource
        }
        // The mic rides the camera AVCaptureSession; pass it only when audio is included.
        let source = self.sourceFactory.makeCameraSource(
            cameraDevice: cameraDevice,
            format: cameraFormat,
            micDevice: includeAudio ? self.micDevice : nil,
            config: self.config
        )
        let encoder = self.encoderFactory.makeEncoder(
            kind: .camera,
            plan: self.plan,
            config: self.config,
            anchor: anchor
        )
        try await encoder.start()

        await monitor.observe(source.drops)
        await monitor.observe(encoder.drops)

        let framesTask = Self.makeFramesTask(source: source, encoder: encoder)
        let routeVideoTask = Self.makeRouteVideoTask(encoder: encoder, kind: .camera, stage: stage)

        self.cameraPipeline = Pipeline(
            kind: .camera,
            source: source,
            encoder: encoder,
            framesTask: framesTask,
            routeVideoTask: routeVideoTask
        )

        if includeAudio {
            // audioSamples → routeAudio. One mic buffer → retimed once → both writers (#33).
            self.audioTask = Task { [weak stage] in
                for await sample in source.audioSamples {
                    await stage?.routeAudio(sample)
                }
            }
        }
    }

    /// frames → `encoder.ingest`. Static so the closure captures only the two sendable actors plus
    /// the optional first-frame hook. `onFirstFrame` is called (once) when the first frame is
    /// delivered; `nil` for the camera pipeline (consent is not required for camera).
    private static func makeFramesTask(
        source: any VideoFrameSource,
        encoder: any EncoderControlling,
        onFirstFrame: (@Sendable () -> Void)? = nil,
        onEndWithoutFirstFrame: (@Sendable () -> Void)? = nil
    )
    -> Task<Void, Never> {
        Task {
            var firstFrameSeen = false
            for await frame in source.frames {
                if !firstFrameSeen {
                    firstFrameSeen = true
                    onFirstFrame?()
                }
                await encoder.ingest(frame)
            }
            // If the stream ended without ever delivering a frame (consent denied / terminal stop),
            // signal the coordinator so it can revert promptly instead of waiting for the full timeout.
            // finish() on the captureActiveContinuation is idempotent: calling it after onFirstFrame
            // already ran is a safe no-op (AsyncStream silently drops the extra finish).
            if !firstFrameSeen {
                onEndWithoutFirstFrame?()
            }
        }
    }

    /// `encoder.encodedSamples` → `stage.routeVideo(_:from:)`.
    private static func makeRouteVideoTask(
        encoder: any EncoderControlling,
        kind: RecordingPipelineKind,
        stage: DualFileOutputStage
    )
    -> Task<Void, Never> {
        Task { [weak stage] in
            for await sample in encoder.encodedSamples {
                await stage?.routeVideo(sample, from: kind)
            }
        }
    }

    // MARK: - Source-event loop (AC-12)

    /// Merges both sources' `events` streams into one loop and applies the AC-12 revoke asymmetry.
    private func startEventLoop() {
        let screenEvents = self.screenPipeline?.source.events
        let cameraEvents = self.cameraPipeline?.source.events

        self.eventLoopTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                if let screenEvents {
                    group.addTask {
                        for await event in screenEvents {
                            await self?.handleSourceEvent(event, from: .screen)
                        }
                    }
                }
                if let cameraEvents {
                    group.addTask {
                        for await event in cameraEvents {
                            await self?.handleSourceEvent(event, from: .camera)
                        }
                    }
                }
            }
        }
    }

    /// Applies the AC-12 revoke asymmetry.
    ///
    /// - `.displayDisconnected` → stop + finalise ONLY the screen pipeline; camera continues.
    /// - `.cameraDisconnected` → stop + finalise the camera pipeline. The mic rides the camera
    ///   AVCaptureSession, so losing the camera ends audio capture: the mic stream finishes, the
    ///   audio task exits, and screen-file audio ends (the screen video track continues). There is
    ///   no track-granular writer API — ending the mic stream IS how the screen audio track is
    ///   "finished".
    /// - `.sourceInterrupted` → log only.
    private func handleSourceEvent(_ event: SourceEvent, from kind: RecordingPipelineKind) async {
        switch event {
        case .displayDisconnected:
            self.logger.notice("AC-12: display disconnected — finalising screen pipeline; camera continues")
            await self.stopAndFinalizePipeline(.screen)
            self.notifyRevocation(.sourceRevoked(.screen))

        case .cameraDisconnected:
            self.logger.notice("AC-12: camera disconnected — finalising camera; screen continues, screen audio ends")
            await self.stopAndFinalizePipeline(.camera)
            self.notifyRevocation(.sourceRevoked(.camera))

        case let .sourceInterrupted(reason):
            self.logger.warning("Source interrupted (\(String(describing: kind))): \(reason) — continuing")
        }
    }

    /// Yields a revocation notification on `sourceRevocationStream`, then — when no video pipeline
    /// remains — yields `.allVideoSourcesLost`.
    ///
    /// Used by both the AC-12 graceful-revoke path (`.sourceRevoked`) and the writer-fault live-UI
    /// path (`.writerFailed`). Centralising the "last pipeline gone" check here avoids duplicating
    /// the `allVideoSourcesLost` logic across call sites.
    ///
    /// Must be called AFTER `stopAndFinalizePipeline` / `takePipeline` so that
    /// `screenPipeline` / `cameraPipeline` accurately reflect which pipelines remain.
    private func notifyRevocation(_ revocation: RecordingRevocation) {
        self.revocationContinuation.yield(revocation)
        if self.screenPipeline == nil, self.cameraPipeline == nil {
            self.logger.notice("Last video pipeline finalised — signalling allVideoSourcesLost")
            self.revocationContinuation.yield(.allVideoSourcesLost)
        }
    }

    /// Handles a single-writer hard fault mid-recording (#197 live UI seam).
    ///
    /// Stops and finalises the faulted pipeline (so we stop burning CPU on a dead writer), then
    /// yields `.writerFailed(kind)` on `sourceRevocationStream` so the `RecordingCoordinator`
    /// immediately flips the corresponding source's liveness to `false`.
    ///
    /// The all-faulted path (`onAllWritersFaulted` → `stop()`) is unchanged — this method is only
    /// reached when the OTHER pipeline is still live.
    private func handleWriterFault(_ kind: RecordingPipelineKind) async {
        self.logger.notice(
            "Writer fault on \(String(describing: kind), privacy: .public) pipeline — stopping faulted pipeline (#197)"
        )
        await self.stopAndFinalizePipeline(kind)
        self.notifyRevocation(.writerFailed(kind))
    }

    /// Stops one pipeline's source + encoder in the load-bearing order, joins its routing tasks,
    /// then finalises just that pipeline's file (AC-12). The other pipeline is untouched.
    private func stopAndFinalizePipeline(_ kind: RecordingPipelineKind) async {
        guard let pipeline = self.takePipeline(kind) else { return }

        await pipeline.source.stop()
        // Do NOT cancel framesTask: source.stop() finishes the `frames` stream (the sources
        // finishAllStreams() in a defer), so the `for await` drains the buffered tail into
        // encoder.ingest and the task completes on its own. Cancelling would make the iterator
        // return nil with up to bufferingNewest(N) frames still buffered — losing exactly the tail
        // that encoder.stop()'s flush must reach the writer (invariant: graceful stop preserves the
        // tail). Symmetric with routeVideoTask below, which is also awaited (never cancelled).
        await pipeline.framesTask.value
        await pipeline.encoder.stop()
        await pipeline.routeVideoTask.value

        if kind == .camera {
            // The mic stream ended with the camera; let the audio task drain and exit so screen
            // audio is sealed before we report.
            await self.audioTask?.value
            self.audioTask = nil
        }

        await self.stage?.finalizePipeline(kind)
    }

    /// Removes and returns a pipeline holder, clearing the stored slot.
    private func takePipeline(_ kind: RecordingPipelineKind) -> Pipeline? {
        switch kind {
        case .screen:
            defer { self.screenPipeline = nil }
            return self.screenPipeline

        case .camera:
            defer { self.cameraPipeline = nil }
            return self.cameraPipeline
        }
    }

    // MARK: - Stop (AC-9)

    /// Stops the session gracefully and returns the assembled result (AC-9).
    ///
    /// Concurrent callers (button / hotkey / menu bar — AC-9) all await the same in-flight Task;
    /// the teardown body runs exactly once regardless of how many callers arrive.
    func stop() async -> RecordingResult {
        // Memoized-task idempotency guard (AC-9). `self.stopTask = task` is assigned synchronously
        // on the actor before the first suspension point, so a concurrent second caller entering
        // stop() always sees the non-nil task and awaits its result — no double teardown.
        if let stopTask { return await stopTask.value }
        // Stop-before-start guard: if the session never entered .running, no teardown is needed.
        // Return .empty immediately without memoizing into stopTask so a subsequent start()→stop()
        // is not poisoned by this no-op.
        guard case .running = self.sessionState else {
            self.logger.notice("RecordingSession.stop() before start() — no-op")
            return .empty(DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            ))
        }
        self.sessionState = .stopped
        let task = Task { await self.performStop() }
        self.stopTask = task
        return await task.value
    }

    // swiftlint:disable function_body_length
    /// Full teardown body — called exactly once via the memoized `stopTask`.
    ///
    /// Stop order is load-bearing (per pipeline, mirrored in `stopAndFinalizePipeline`):
    /// `source.stop()` → join frames→ingest task → `encoder.stop()` (flush) → join encoded→routeVideo
    /// task → (camera) drain audio task → `markFinished()` → parallel `finish()` (one `.failed` must
    /// not fail the other) → assemble `RecordingResult`.
    private func performStop() async -> RecordingResult {
        // Stop both video pipelines in the correct order (sources → encoders → routing joined).
        for kind in [RecordingPipelineKind.screen, .camera] {
            guard let pipeline = self.takePipeline(kind) else { continue }
            await pipeline.source.stop()
            // Do NOT cancel framesTask — see stopAndFinalizePipeline: source.stop() finishes the
            // frames stream so the task drains the buffered tail into encoder.ingest and ends on its
            // own; cancelling would lose that tail before encoder.stop() flushes it.
            await pipeline.framesTask.value
            await pipeline.encoder.stop()
            await pipeline.routeVideoTask.value
        }

        // The mic stream finished when the camera source stopped; drain the audio task tail.
        await self.audioTask?.value
        self.audioTask = nil

        // The event loop's child streams finished with their sources; let it exit.
        self.eventLoopTask?.cancel()
        await self.eventLoopTask?.value
        self.eventLoopTask = nil

        // markFinished + parallel finish on every remaining writer (AC-9 independence).
        let finishResults = await self.stage?.finishAll() ?? [:]

        // Log any writer failures so they are never silently dropped.
        for (kind, finishResult) in finishResults {
            if case let .failed(url, error) = finishResult {
                self.logger.error(
                    "Writer \(String(describing: kind)) failed — url=\(url.lastPathComponent) error=\(error)"
                )
            }
        }

        // Stop the monitor first so its observe tasks fully drain before snapshot().
        // encoder.stop() finished the drop streams; dropMonitor.stop() awaits those tasks, ensuring
        // every in-flight DropEvent is ingested before the counters are read.
        await self.dropMonitor?.stop()
        let healthSnapshot = await self.dropMonitor?.snapshot()
            ?? DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
        // Per-source breakdown is read here (before the monitor is released) so the technical report
        // below can include the source-level detail in addition to the reason-level snapshot.
        let breakdown = await self.dropMonitor?.breakdownSnapshot()
            ?? DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encode: 0,
                writer: 0
            )
        self.dropMonitor = nil

        // End the UI state forwarding: dropMonitor.stop() already finished the monitor's state
        // stream (so the loop ends on its own), but cancel + finish the continuation explicitly so
        // the coordinator's `for await` over `recordingStateStream` terminates deterministically.
        self.stateForwardingTask?.cancel()
        await self.stateForwardingTask?.value
        self.stateForwardingTask = nil
        self.stateContinuation.finish()

        // End the revocation stream so the coordinator's `for await` over sourceRevocationStream
        // terminates. No task to cancel — the session yields directly from handleSourceEvent.
        self.revocationContinuation.finish()

        // End the capture-active stream. If the first-frame hook already finished it (normal path:
        // consent was granted), this is a no-op. If stop() is called before the first frame arrives
        // (stop during consent wait), finishing here unblocks the coordinator's activation wait so it
        // can detect the empty finish and revert cleanly (#171).
        self.captureActiveContinuation.finish()

        let sessionOutput = SessionOutput(screen: finishResults[.screen], camera: finishResults[.camera])
        let result: RecordingResult = if let output = sessionOutput {
            .completed(output, healthSnapshot)
        } else {
            .empty(healthSnapshot)
        }

        // Persist the per-session technical report next to the recording files. Frame-loss is no
        // longer surfaced in the UI (no live drop pill, no post-stop warning alert) — it lives on
        // disk as a plain-text report instead. Written only for sessions that produced output
        // (`.completed`): the `.empty` path created no files (and possibly no session directory), so
        // there is nothing to attach a report to.
        if case .completed = result {
            self.writeTechnicalReport(snapshot: healthSnapshot, breakdown: breakdown)
        }

        let warn = result.degradedWarning(threshold: self.config.postStopDropWarningThreshold)
        self.logger.info(
            // swiftlint:disable:next line_length
            "RecordingSession stopped — files=\(result.outputURLs.count) warn=\(warn) cause=\(String(describing: result.dominantCause))"
        )
        return result
    }

    // swiftlint:enable function_body_length

    // MARK: - Technical report

    /// Formats and writes the per-session technical report into the session directory.
    ///
    /// Formatting (pure) is delegated to `DropReportFormatter`; the file write + POSIX permissions
    /// (impure) live in `RecordingOutput.writeReport`. A write failure is logged and swallowed — the
    /// report is a diagnostic artifact and must never fail the stop path or mask the recording result.
    private func writeTechnicalReport(snapshot: DropHealthSnapshot, breakdown: DropBreakdown) {
        let text = DropReportFormatter.report(
            timestamp: self.sessionStartDate,
            counters: snapshot.counters,
            breakdown: breakdown,
            sessionEverDegraded: snapshot.sessionEverDegraded,
            dominantCause: snapshot.dominantCause
        )
        do {
            try RecordingOutput.writeReport(text, in: self.sessionDirectory, timestamp: self.sessionStartDate)
            self.logger.info(
                "Technical report written: \(RecordingOutput.reportFileName(timestamp: self.sessionStartDate))"
            )
        } catch {
            // Diagnostic-only artifact: never fail stop on a report-write error. Log the directory
            // name (not the full path) to avoid logging the user's home path (#188).
            self.logger.error(
                "Technical report write failed in \(self.sessionDirectory.lastPathComponent) — \(error)"
            )
        }
    }

    // MARK: - Failure teardown

    /// Best-effort teardown when `start()` throws after some components were built.
    private func teardownAfterFailedStart() async {
        if let screen = self.takePipeline(.screen) {
            screen.framesTask.cancel()
            screen.routeVideoTask.cancel()
            await screen.source.stop()
            await screen.encoder.stop()
        }
        if let camera = self.takePipeline(.camera) {
            camera.framesTask.cancel()
            camera.routeVideoTask.cancel()
            await camera.source.stop()
            await camera.encoder.stop()
        }
        self.audioTask?.cancel()
        self.audioTask = nil
        self.eventLoopTask?.cancel()
        self.eventLoopTask = nil
        // Tear down UI state forwarding spun in start() before the throw (it may have started as
        // early as makeStage()'s monitor). Finish the continuation so a subscriber's loop ends.
        self.stateForwardingTask?.cancel()
        self.stateForwardingTask = nil
        self.stateContinuation.finish()
        // Finish the revocation stream too, so a subscriber's loop ends after a failed start.
        self.revocationContinuation.finish()
        // Finish the capture-active stream so a waiting coordinator unblocks and reverts (#171).
        self.captureActiveContinuation.finish()
        // Cancel (not drain) the monitor's observe tasks: this path does NOT call stage.finishAll(),
        // so if a writer was created and its drops observed just before the start threw, that stream
        // may still be open. DropMonitor.stop() drains and would hang on an unfinished stream (#202);
        // cancelObservation() ends the observe tasks regardless. Tail accuracy is irrelevant on a
        // failed start — no RecordingResult reads these counters.
        await self.dropMonitor?.cancelObservation()
        self.dropMonitor = nil
        self.stage = nil
    }
}

// swiftlint:enable type_body_length
// file_length stays disabled through EOF: re-enabling a whole-file rule before the last line
// would re-trigger on the total count (same pattern as FileWriter / DualFileOutputStage).
