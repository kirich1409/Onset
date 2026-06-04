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
    init(
        cameraDevice: CameraDevice,
        format: CameraFormat,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration
    ) {
        self.cameraDevice = cameraDevice
        self.format = format
        self.micDevice = micDevice
        self.config = config

        var capturedFrames: AsyncStream<VideoFrame>.Continuation!
        var capturedAudio: AsyncStream<AudioSample>.Continuation!
        var capturedEvents: AsyncStream<SourceEvent>.Continuation!
        var capturedDrops: AsyncStream<DropEvent>.Continuation!

        self.frames = AsyncStream(
            VideoFrame.self,
            bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)
        ) { capturedFrames = $0 }

        self.audioSamples = AsyncStream(
            AudioSample.self,
            bufferingPolicy: .bufferingNewest(Self.audioBufferDepth)
        ) { capturedAudio = $0 }

        self.events = AsyncStream(
            SourceEvent.self,
            bufferingPolicy: .bufferingNewest(Self.eventsBufferDepth)
        ) { capturedEvents = $0 }

        self.drops = AsyncStream(
            DropEvent.self,
            bufferingPolicy: .bufferingNewest(Self.dropsBufferDepth)
        ) { capturedDrops = $0 }

        self.framesContinuation = capturedFrames
        self.audioSamplesContinuation = capturedAudio
        self.eventsContinuation = capturedEvents
        self.dropsContinuation = capturedDrops
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
    }

    /// Stops capture. Finishes all four streams idempotently.
    func stop() async {
        defer { self.finishAllStreams() }
        guard case let .running(session, shims) = self.captureState else {
            self.captureState = .stopped
            return
        }
        self.captureState = .stopped
        NotificationCenter.default.removeObserver(shims.video)
        session.stopRunning()
        cameraSourceLogger.info("Capture stopped")
    }

    // MARK: - Terminal-stop handling

    /// Called by the delegate shim when the camera device disconnects.
    func handleCameraDisconnect() async {
        guard case let .running(session, shims) = self.captureState else { return }
        self.captureState = .stopped
        NotificationCenter.default.removeObserver(shims.video)
        session.stopRunning()
        cameraSourceLogger.error("Camera device disconnected — stopping")
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

    // MARK: - Stream teardown

    private func finishAllStreams() {
        self.framesContinuation.finish()
        self.audioSamplesContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }
}
