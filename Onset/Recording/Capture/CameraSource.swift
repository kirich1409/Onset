import AVFoundation
import CoreMedia
import os

// MARK: - Logger

/// Logger is `Sendable`; `nonisolated let` avoids a `@MainActor` hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated let cameraSourceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CameraSource"
)

// MARK: - CameraSource

/// Captures camera video and microphone audio via a single `AVCaptureSession`.
///
/// ### Dual-protocol design
/// `CameraSource` conforms to both `VideoFrameSource` and `AudioSampleSource`. Both
/// protocols require a `drops: AsyncStream<DropEvent>` property. A single `drops` stream
/// satisfies both requirements simultaneously — the drop stream is shared, reflecting
/// that video `captureDrop` events (from `AVCaptureVideoDataOutputSampleBufferDelegate
/// .captureOutput(_:didDrop:from:)`) and backpressure drops (from buffer overflow) are
/// all emitted on the same channel. There is no `DropReason` case distinguishing audio
/// capture-level drops from video capture-level drops — this is a protocol contract
/// limitation, documented here rather than hidden.
///
/// ### Session clock and host-time conversion
/// After `beginConfiguration` / `commitConfiguration` with both video and audio inputs
/// added, `AVCaptureSession.synchronizationClock` may adopt the audio device's clock
/// rather than the host clock — this is common when a microphone input is present. All
/// PTS values from both delegates are converted at ingest using
/// `CMSyncConvertTime(pts, from: session.synchronizationClock, to: CMClockGetHostTimeClock())`.
/// This is safe even when the session clock happens to be the host clock: `CMSyncConvertTime`
/// returns the input unchanged in that case. The `sourceClock` is captured once after
/// configuration and injected immutably into both shims.
///
/// ### Preview (`SessionHandle`)
/// The actor exposes a `SessionHandle` via the `sessionHandle()` accessor after a successful
/// `start()`. MainActor consumers `await source.sessionHandle()` and pass the result to
/// `AVCaptureVideoPreviewLayer(session:)`. Returns `nil` when not in the `.running` state.
/// See `SessionHandle` for the `@unchecked Sendable` rationale.
actor CameraSource: VideoFrameSource, AudioSampleSource {
    // MARK: - Constants

    /// Buffer depth for `frames`. Modest to release CVPixelBuffers promptly; matches #28.
    private static let framesBufferDepth = 4

    /// Buffer depth for `audioSamples`. Modest — audio samples are small, consumer is fast.
    private static let audioBufferDepth = 8

    /// Buffer depth for `drops`. Decoupled from the frame buffer depth per #28 lesson.
    private static let dropsBufferDepth = 8

    /// Buffer depth for `events`. 4 slots: headroom for teardown races.
    private static let eventsBufferDepth = 4

    // MARK: - Protocol streams (nonisolated let — no actor hop for subscribers)

    nonisolated let frames: AsyncStream<VideoFrame>
    nonisolated let audioSamples: AsyncStream<AudioSample>
    nonisolated let events: AsyncStream<SourceEvent>
    nonisolated let drops: AsyncStream<DropEvent>

    // MARK: - Internal state (internal for extension-based decomposition across files)

    let cameraDevice: CameraDevice
    let format: CameraFormat
    let micDevice: MicrophoneDevice?
    let config: RecordingConfiguration
    /// Which lifecycle this source serves; controls data-output attachment and telemetry.
    let role: CaptureRole
    let framesContinuation: AsyncStream<VideoFrame>.Continuation
    let audioSamplesContinuation: AsyncStream<AudioSample>.Continuation
    let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    let dropsContinuation: AsyncStream<DropEvent>.Continuation

    let videoQueue = DispatchQueue(
        label: "dev.androidbroadcast.Onset.CameraSource.videoOutput",
        qos: .userInteractive
    )
    let audioQueue = DispatchQueue(
        label: "dev.androidbroadcast.Onset.CameraSource.audioOutput",
        qos: .userInteractive
    )

    var captureState: CameraCaptureState = .idle

    // MARK: - Telemetry

    /// Lock shared with `VideoOutputShim` so the shim (running on `videoQueue`) and this actor's
    /// flush tick can both safely access the same `StageRateAggregator` struct.
    ///
    /// Created once in `init`; nominalFps is derived from `config.minCameraFps` (the configured
    /// target; the actual negotiated rate may differ but is unavailable at init time).
    let captureRateLock: OSAllocatedUnfairLock<StageRateAggregator>

    /// ~1 s periodic flush task started after a successful session start, cancelled in `stop()`.
    var captureTelemetryTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a `CameraSource`.
    ///
    /// All `AsyncStream`s are created here so consumers can subscribe before
    /// `start(anchoredTo:)` is called without missing any events.
    ///
    /// - Parameters:
    ///   - cameraDevice: The camera device snapshot (from `CaptureDeviceModels`).
    ///   - format: The pre-selected best format (from `CameraFormatSelector`).
    ///   - micDevice: Optional microphone device. When `nil`, `audioSamples` never delivers.
    ///   - config: Recording policy (fps target from `config.minCameraFps`).
    ///   - role: Which lifecycle this source serves (default `.record`; pass `.preview` for
    ///     preview-only instances that must not attach a data output or run telemetry).
    init(
        cameraDevice: CameraDevice,
        format: CameraFormat,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration,
        role: CaptureRole = .record
    ) {
        self.cameraDevice = cameraDevice
        self.format = format
        self.micDevice = micDevice
        self.config = config
        self.role = role

        let (frames, framesContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)
        )
        self.frames = frames
        self.framesContinuation = framesContinuation

        let (audioSamples, audioSamplesContinuation) = AsyncStream.makeStream(
            of: AudioSample.self,
            bufferingPolicy: .bufferingNewest(Self.audioBufferDepth)
        )
        self.audioSamples = audioSamples
        self.audioSamplesContinuation = audioSamplesContinuation

        let (events, eventsContinuation) = AsyncStream.makeStream(
            of: SourceEvent.self,
            bufferingPolicy: .bufferingNewest(Self.eventsBufferDepth)
        )
        self.events = events
        self.eventsContinuation = eventsContinuation

        let (drops, dropsContinuation) = AsyncStream.makeStream(
            of: DropEvent.self,
            bufferingPolicy: .bufferingNewest(Self.dropsBufferDepth)
        )
        self.drops = drops
        self.dropsContinuation = dropsContinuation

        self.captureRateLock = OSAllocatedUnfairLock(
            initialState: StageRateAggregator(
                lane: "camera",
                stage: .capture,
                nominalFps: config.minCameraFps,
                role: role
            )
        )
    }

    // MARK: - VideoFrameSource + AudioSampleSource

    /// Starts camera + microphone capture, anchored to `anchor`.
    ///
    /// `.idle → .starting` is set synchronously before the first `await` so a racing
    /// second invocation sees `.starting` and returns immediately.
    ///
    /// - Throws: `RecordingError.noSuitableCameraFormat` / `.captureSetupFailed`.
    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        guard case .idle = self.captureState else {
            cameraSourceLogger.info("start() called in non-idle state — ignoring")
            return
        }
        self.captureState = .starting

        do {
            try await self.buildAndStartSession(anchor: anchor)
        } catch {
            // Use .stopped, not .idle: all four continuations are finished after
            // finishAllStreams() and cannot be re-used. .idle would advertise this
            // instance as restartable, leading to a silent zero-frame session on retry.
            self.captureState = .stopped
            self.finishAllStreams()
            throw error
        }
        // Preview emits no frames — an all-zero line every second is log noise.
        // Gate on .running too: the stop()-during-start abort path returns normally with
        // state .stopped (stop() already ran its cancel), so telemetry must not start — #203.
        if shouldStartCaptureTelemetry(role: self.role, state: self.captureState) {
            self.startCaptureTelemetryTask(anchor: anchor)
        }
    }

    /// Stops capture. Finishes all four streams idempotently.
    func stop() async {
        self.captureTelemetryTask?.cancel()
        self.captureTelemetryTask = nil
        defer { self.finishAllStreams() }
        guard case let .running(session, shims) = self.captureState else {
            self.captureState = .stopped
            return
        }
        self.captureState = .stopped
        NotificationCenter.default.removeObserver(shims.video)
        shims.suspensionObservation.invalidate()
        self.releaseRunning(shims: shims, session: session)
        cameraSourceLogger.info("Capture stopped")
    }

    /// Releases the held configuration lock (if any) and stops the session.
    ///
    /// Single teardown point for the `.record` device lock that `buildAndStartSession` acquires
    /// before `configureSession` and holds through the whole record session (#265).
    /// `shims.lockedDevice` is `nil` for `.preview` (already unlocked) — the optional-chained
    /// `unlockForConfiguration()` is then a no-op. `unlockForConfiguration()` on a
    /// disconnected/faulted device is also a safe no-op, so the disconnect/fault teardown paths
    /// may call this unconditionally.
    private func releaseRunning(shims: CameraCaptureShims, session: AVCaptureSession) {
        shims.lockedDevice?.unlockForConfiguration()
        session.stopRunning()
    }

    // MARK: - Terminal-stop handling

    /// Called by the delegate shim when the camera device disconnects.
    func handleCameraDisconnect() async {
        self.captureTelemetryTask?.cancel()
        self.captureTelemetryTask = nil
        guard case let .running(session, shims) = self.captureState else { return }
        self.captureState = .stopped
        NotificationCenter.default.removeObserver(shims.video)
        shims.suspensionObservation.invalidate()
        self.releaseRunning(shims: shims, session: session)
        cameraSourceLogger.error("Camera device disconnected — stopping")
        self.eventsContinuation.yield(.cameraDisconnected)
        self.finishAllStreams()
    }

    /// Called by the delegate shim when the `AVCaptureSession` faults (runtime error or
    /// interruption). Treated as terminal — consistent with the one-shot / no-restart design.
    ///
    /// Reuses the `.cameraDisconnected` event path so the existing consumer
    /// (`stopAndFinalizePipeline(.camera)`) produces a valid, finalized camera MP4 up to the
    /// fault point while the screen pipeline continues unaffected.
    ///
    /// The `.running` guard provides idempotency: a simultaneous disconnect + fault race
    /// is safe — the second caller finds `.stopped` and returns without double-finishing.
    func handleCameraSessionFault(reason: String) async {
        self.captureTelemetryTask?.cancel()
        self.captureTelemetryTask = nil
        guard case let .running(session, shims) = self.captureState else { return }
        self.captureState = .stopped
        NotificationCenter.default.removeObserver(shims.video)
        shims.suspensionObservation.invalidate()
        self.releaseRunning(shims: shims, session: session)
        cameraSourceLogger.error("Camera session fault — stopping: \(reason, privacy: .public)")
        self.eventsContinuation.yield(.cameraDisconnected)
        self.finishAllStreams()
    }

    // MARK: - Preview

    /// Returns a `SessionHandle` wrapping the live `AVCaptureSession`, or `nil` when
    /// capture is not in the `.running` state (before `start()`, after `stop()`, or after
    /// a disconnect).
    ///
    /// Callers must `await` this accessor — the actor hop is intentional and replaces the
    /// former `nonisolated(unsafe) var sessionHandle` field that had no thread-safety guarantee.
    func sessionHandle() -> SessionHandle? {
        guard case let .running(session, _) = self.captureState else { return nil }
        return SessionHandle(session: session)
    }

    // MARK: - Telemetry task

    func startCaptureTelemetryTask(anchor: HostTimeAnchor) {
        // T0 in host-clock seconds; the snapshot freshness stamp is expressed relative to it so it
        // shares the session-relative frame the coordinator's `elapsedSeconds` uses (see below).
        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        self.captureTelemetryTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastInstant = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let elapsedSeconds = (now - lastInstant).totalSeconds
                lastInstant = now
                // Freshness stamp = seconds since session T0 (host_now − T0). This matches the
                // SESSION-RELATIVE frame of FpsCollapseDetector's `elapsedSeconds` (zero at start),
                // so the coordinator can pass `snapshot.monotonicStampSeconds` straight in as
                // `sampleElapsedSeconds` with no conversion — and `pastWarmup`/staleness stay correct.
                let monotonicSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - anchorSeconds
                // Single lock acquisition: flush stores the numeric snapshot (and resets the log
                // accumulators); stampSnapshot publishes it with the freshness stamp atomically.
                let line = self.captureRateLock.withLock { aggregator -> String? in
                    let line = aggregator.flush(elapsedSeconds: elapsedSeconds)
                    aggregator.stampSnapshot(monotonicSeconds: monotonicSeconds)
                    return line
                }
                if let line {
                    telemetryLogger.notice("\(line, privacy: .public)")
                } else {
                    cameraSourceLogger.debug("flushTelemetry: skipped (elapsed ≤ 0)")
                }
            }
        }
    }

    // MARK: - Rate snapshot pull (T-B.2)

    /// Returns the latest camera rate snapshot under `captureRateLock`.
    ///
    /// `nonisolated`: the snapshot lives behind `captureRateLock` (the same point that synchronizes
    /// the `VideoOutputShim` writes and the flush tick), so this needs no actor hop and acquires no
    /// new lock — it reuses the existing one. Returns `nil` until the first flush + stamp pair runs.
    nonisolated func currentRateSnapshot() -> CameraRateSnapshot? {
        self.captureRateLock.withLock { $0.latestCameraSnapshot }
    }

    // MARK: - Stream teardown

    private func finishAllStreams() {
        self.framesContinuation.finish()
        self.audioSamplesContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }
}
