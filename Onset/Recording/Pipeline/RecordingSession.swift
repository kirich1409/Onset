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
    /// The explicit frame rate to lock when activating the camera format in `CameraSource`.
    /// Sourced from `RecordingRequest.cameraModeTargetFps` (set by the user's CameraMode selection).
    private let cameraModeTargetFps: Int
    private let micDevice: MicrophoneDevice?
    private let config: RecordingConfiguration

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
    ///   - cameraModeTargetFps: The explicit frame rate to lock when activating the camera format.
    ///     Sourced from the user's CameraMode selection. Defaults to `config.minCameraFps` when
    ///     called from tests or the backward-compatible path.
    ///   - micDevice: The selected microphone, or `nil` (no audio).
    ///   - config: Recording policy.
    ///   - probe: Capability pre-flight (AC-6). Defaults to the live `CapabilityProbe`.
    ///   - encoderFactory / writerFactory / sourceFactory: DI seams (live by default).
    init(
        plan: ResolvedRecordingPlan,
        display: Display,
        cameraDevice: CameraDevice?,
        cameraFormat: CameraFormat?,
        cameraModeTargetFps: Int? = nil,
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
        self.cameraModeTargetFps = cameraModeTargetFps ?? config.minCameraFps
        self.micDevice = micDevice
        self.config = config
        self.encoderFactory = encoderFactory
        self.sourceFactory = sourceFactory

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

        // Default live probe: classify against the resolved display + camera format.
        self.probe = probe ?? { CapabilityProbe.probe(display: display, cameraFormat: cameraFormat, config: config) }

        // Default live writer factory: place both files in the configured output directory.
        self.writerFactory = writerFactory ?? LiveWriterFactory(configuration: config) { kind in
            RecordingSession.defaultOutputURL(for: kind, config: config)
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

        // Ensure the output directory exists before any FileWriter is constructed.
        // Placed after resolvePlan so the directory is only created when recording will
        // actually proceed, and before the T0 anchor capture so filesystem I/O does not
        // perturb the timing-critical window.
        do {
            try RecordingOutput.ensureDirectory(self.config.outputDirectory)
        } catch {
            self.logger.error("Output directory unavailable: \(self.config.outputDirectory.path) — \(error)")
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
    private func startSources(anchor: HostTimeAnchor) async throws {
        if let screen = self.screenPipeline {
            try await screen.source.start(anchoredTo: anchor)
        }
        if let camera = self.cameraPipeline {
            try await camera.source.start(anchoredTo: anchor)
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

    /// The session's cumulative drop counters, polled by the UI (`RecordingCoordinator`) for the
    /// recording-window drop pill. Returns a zero-counter snapshot before `start()` builds the
    /// monitor or after `performStop()` tears it down.
    func currentDrops() async -> DropCounters {
        await self.dropMonitor?.snapshot()
            ?? DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0)
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

        let framesTask = Self.makeFramesTask(source: source, encoder: encoder)
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
            config: self.config,
            targetFps: self.cameraModeTargetFps
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

    /// frames → `encoder.ingest`. Static so the closure captures only the two sendable actors.
    private static func makeFramesTask(
        source: any VideoFrameSource,
        encoder: any EncoderControlling
    )
    -> Task<Void, Never> {
        Task {
            for await frame in source.frames {
                await encoder.ingest(frame)
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
            self.notifyRevocation(of: .screen)

        case .cameraDisconnected:
            self.logger.notice("AC-12: camera disconnected — finalising camera; screen continues, screen audio ends")
            await self.stopAndFinalizePipeline(.camera)
            self.notifyRevocation(of: .camera)

        case let .sourceInterrupted(reason):
            self.logger.warning("Source interrupted (\(String(describing: kind))): \(reason) — continuing")
        }
    }

    /// Yields the AC-12 revocation notification (#39 UI seam) AFTER `stopAndFinalizePipeline` has
    /// niled the finalised pipeline's slot: `.sourceRevoked(kind)`, then `.allVideoSourcesLost` when
    /// no video pipeline remains. Called only on the AC-12 finalize arms — does NOT alter the
    /// finalize behaviour itself (Epic-3-verified), only notifies the single-consumer coordinator.
    private func notifyRevocation(of kind: RecordingPipelineKind) {
        self.revocationContinuation.yield(.sourceRevoked(kind))
        if self.screenPipeline == nil, self.cameraPipeline == nil {
            self.logger.notice("AC-12: last video pipeline finalised — signalling allVideoSourcesLost")
            self.revocationContinuation.yield(.allVideoSourcesLost)
        }
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
            return .empty(DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0))
        }
        self.sessionState = .stopped
        let task = Task { await self.performStop() }
        self.stopTask = task
        return await task.value
    }

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
        let counters = await self.dropMonitor?.snapshot()
            ?? DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0)
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

        let sessionOutput = SessionOutput(screen: finishResults[.screen], camera: finishResults[.camera])
        let result: RecordingResult = if let output = sessionOutput {
            .completed(output, counters)
        } else {
            .empty(counters)
        }
        self.logger.info("RecordingSession stopped — files=\(result.outputURLs.count) warn=\(result.degradedWarning)")
        return result
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
        await self.dropMonitor?.stop()
        self.dropMonitor = nil
        self.stage = nil
    }

    // MARK: - Default output URL

    /// Builds the default output URL for a pipeline under the configured output directory.
    private static func defaultOutputURL(
        for kind: RecordingPipelineKind,
        config: RecordingConfiguration
    )
    -> URL {
        let suffix = switch kind {
        case .screen:
            "screen"

        case .camera:
            "camera"
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        return config.outputDirectory
            .appending(path: "Onset-\(timestamp)-\(suffix).mp4")
    }
}

// swiftlint:enable type_body_length
// file_length stays disabled through EOF: re-enabling a whole-file rule before the last line
// would re-trigger on the total count (same pattern as FileWriter / DualFileOutputStage).
