import CoreMedia

// MARK: - RetimedAudioBuffer

/// Carries a retimed PCM `CMSampleBuffer` into each writer (#33 fan-out).
///
/// `@unchecked Sendable` for the same reason as `AudioSample` / `EncodedSample` in
/// `PipelineTypes.swift`: `CMSampleBuffer` is a non-`Sendable` reference type, but the buffer is
/// immutable after the retime copy is created, so handing the SAME reference to both writer actors
/// is sound. A dedicated box (not `AudioSample`) is used because `AudioSample.ptsHostTime` is the
/// PRE-retime absolute time and is redundant/misleading once the buffer has been retimed.
nonisolated struct RetimedAudioBuffer: @unchecked Sendable {
    /// The retimed PCM sample buffer (timestamps already in the absolute host-time domain).
    ///
    /// `nonisolated` cannot be applied because `CMSampleBuffer` is not `Sendable` (same constraint
    /// as `LiveWriterInput.input`); the `@unchecked Sendable` on the struct is what makes the
    /// carrier safe to share across isolation.
    let buffer: CMSampleBuffer
}

// MARK: - EncoderControlling

/// The exact surface `RecordingSession` / `DualFileOutputStage` use of a video encoder.
///
/// Abstracts `VideoEncoder` (the concrete actor) so tests can substitute a fake that emits
/// `EncodedSample`s deterministically. Only the orchestration-facing members are declared —
/// the protocol deliberately does NOT mirror the full `VideoEncoder` type.
///
/// ### `clockTick()` is intentionally absent
/// In production each encoder is `selfClocked: true` and drives its own CFR grid; `RecordingSession`
/// owns only T0, not the tick (the two grids run at different fps — one driver cannot serve both,
/// see `RecordingSession`). In tests the encoder fake emits `EncodedSample`s through its own hook
/// rather than via `clockTick()`, which is simpler and equally deterministic. So `clockTick()`
/// belongs to neither the orchestrator nor this protocol.
///
/// `nonisolated protocol` so conformers (actors) satisfy the `async` requirements without the
/// protocol itself being inferred `@MainActor` (mirrors `WriterInputSeam` / `CompressionSession`).
nonisolated protocol EncoderControlling: Sendable {
    /// Encoded HEVC samples in decode order. Subscribed nonisolated (no actor hop on the hot path).
    nonisolated var encodedSamples: AsyncStream<EncodedSample> { get }

    /// Encoder-side backpressure drop events for `DropMonitor`.
    nonisolated var drops: AsyncStream<DropEvent> { get }

    /// Creates and configures the underlying compression session. Throws on the AC-6 no-HW path.
    func start() async throws

    /// Feeds one captured frame into the encoder.
    func ingest(_ frame: VideoFrame) async

    /// Stops the encoder: flushes pending frames to final samples, then finishes the streams.
    func stop() async
}

/// `VideoEncoder` already exposes exactly this surface — conformance is a declaration only.
extension VideoEncoder: EncoderControlling {}

// MARK: - WriterControlling

/// The exact surface `DualFileOutputStage` uses of a file writer.
///
/// Abstracts `FileWriter` (the concrete actor) so tests can substitute a fake that records the
/// `startSession` source time, captures appended buffer references (for fan-out identity
/// assertions), and reports a configurable `FinishResult`.
///
/// Note: there is deliberately NO track-granular finish here. `FileWriter` finalises both tracks
/// together via `markFinished()`; AC-12's "end the screen file's audio track" is realised by the
/// stage simply ceasing to route audio to that writer once the mic stream ends — not by a writer
/// API. (See `DualFileOutputStage` AC-12 handling.)
nonisolated protocol WriterControlling: Sendable {
    /// Writer-side backpressure drop events for `DropMonitor`. Registered at writer creation.
    nonisolated var drops: AsyncStream<DropEvent> { get }

    /// Hard-fault events emitted exactly once when the writer enters the faulted state.
    ///
    /// Emits a single `Void` value when `AVAssetWriter.append()` returns `false` (terminal,
    /// non-recoverable), then the stream finishes. Consumers that observe this stream should
    /// treat its completion as an early-stop signal (#105 fail-fast path).
    nonisolated var faults: AsyncStream<Void> { get }

    /// Establishes the timeline origin. MUST be passed the session's verbatim T0 (AC-7) — never
    /// `.zero`, never first-sample PTS.
    func start(atSourceTime sourceTime: CMTime) async throws

    /// Appends a compressed HEVC sample to the video track (raw — no PTS conversion).
    func appendVideo(_ sample: EncodedSample) async

    /// Appends a (retimed) PCM audio buffer to the audio track.
    ///
    /// Takes a `RetimedAudioBuffer` (not a raw `CMSampleBuffer`) so the non-`Sendable` buffer can
    /// cross into the writer actor as part of a `Sendable` carrier — exactly how `appendVideo`
    /// crosses with the `@unchecked Sendable` `EncodedSample`. The SAME carrier is handed to both
    /// writers (#33 fan-out identity).
    func appendAudio(_ audio: RetimedAudioBuffer) async

    /// Marks all inputs finished. Call before `finish()`.
    func markFinished() async

    /// Finalises the file and returns the terminal outcome.
    func finish() async -> FinishResult
}

/// `FileWriter` already exposes `start(atSourceTime:)`, `appendVideo`, `markFinished`, `finish`,
/// and `drops` directly. Only `appendAudio` needs an adapter: it unwraps the `RetimedAudioBuffer`
/// carrier inside the actor and forwards to `FileWriter`'s existing `appendAudio(_:CMSampleBuffer)`.
/// The unwrap is an actor-internal call (no isolation hop, no transfer). Adding this extension does
/// NOT modify the closed `FileWriter` leaf.
extension FileWriter: WriterControlling {
    func appendAudio(_ audio: RetimedAudioBuffer) {
        self.appendAudio(audio.buffer)
    }
}

// MARK: - EncoderFactory

/// Builds an `EncoderControlling` for one pipeline, sharing the session's single `HostTimeAnchor`.
///
/// The live implementation wraps `VideoEncoder(selfClocked: true)` so each encoder self-drives its
/// own CFR grid off the ONE shared anchor (AC-7: shared T0 epoch + host-rooted PTS, NOT a shared
/// tick). Tests inject a fake to drive sample emission deterministically.
nonisolated protocol EncoderFactory: Sendable {
    /// - Parameters:
    ///   - kind: Which pipeline this encoder serves (selects the resolved dimensions / fps).
    ///   - plan: The resolved capture plan (screen dimensions + optional camera plan).
    ///   - config: The recording policy (bitrate table, profile, GOP).
    ///   - anchor: The session's single shared T0 anchor.
    func makeEncoder(
        kind: RecordingPipelineKind,
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration,
        anchor: HostTimeAnchor
    )
        -> any EncoderControlling
}

/// Live factory: builds a real `VideoEncoder` per pipeline from the resolved plan.
nonisolated struct LiveEncoderFactory: EncoderFactory {
    func makeEncoder(
        kind: RecordingPipelineKind,
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration,
        anchor: HostTimeAnchor
    )
    -> any EncoderControlling {
        let width: Int
        let height: Int
        let fps: Int
        switch kind {
        case .screen:
            width = plan.screenWidth
            height = plan.screenHeight
            fps = plan.screenFps

        case .camera:
            // A camera encoder is only built when the plan has a camera; the force-unwrap is
            // guarded by RecordingSession, which never asks for a camera encoder without a plan.
            guard let cameraPlan = plan.cameraPlan else {
                preconditionFailure("camera encoder requested without a ResolvedCameraPlan")
            }
            width = cameraPlan.width
            height = cameraPlan.height
            fps = cameraPlan.fps
        }

        let settings = EncoderConfigBuilder.build(config: config, width: width, height: height, fps: fps)
        return VideoEncoder(
            settings: settings,
            width: Int32(width),
            height: Int32(height),
            fps: fps,
            anchor: anchor,
            selfClocked: true,
            label: kind == .screen ? "screen" : "camera"
        )
    }
}

// MARK: - WriterFactory

/// Builds a `WriterControlling` lazily — only once the first `EncodedSample` of a pipeline has
/// arrived, because the writer init needs the `CMFormatDescription` extracted from that sample
/// (`FileWriter` requires a non-nil `sourceFormatHint` for MP4 passthrough).
nonisolated protocol WriterFactory: Sendable {
    /// - Parameters:
    ///   - kind: Which pipeline this writer serves (selects the output URL).
    ///   - sourceFormatHint: The HEVC `CMFormatDescription` from the pipeline's first sample.
    ///   - includeAudio: Whether to mux a microphone audio track.
    /// - Throws: `RecordingError.writerSetupFailed` (or the underlying error) if the writer
    ///   cannot be constructed for the output URL.
    func makeWriter(
        kind: RecordingPipelineKind,
        sourceFormatHint: CMFormatDescription,
        includeAudio: Bool
    ) throws
        -> any WriterControlling
}

/// Live factory: builds a real `FileWriter` per pipeline, resolving the output URL from config.
nonisolated struct LiveWriterFactory: WriterFactory {
    private let configuration: RecordingConfiguration
    private let urlProvider: @Sendable (RecordingPipelineKind) -> URL

    /// - Parameters:
    ///   - configuration: Recording policy (fragment interval, audio settings).
    ///   - urlProvider: Resolves the destination URL for a pipeline. Injected so `RecordingSession`
    ///     can place both files in a single session-scoped directory with consistent base names.
    nonisolated init(
        configuration: RecordingConfiguration,
        urlProvider: @escaping @Sendable (RecordingPipelineKind) -> URL
    ) {
        self.configuration = configuration
        self.urlProvider = urlProvider
    }

    func makeWriter(
        kind: RecordingPipelineKind,
        sourceFormatHint: CMFormatDescription,
        includeAudio: Bool
    ) throws
    -> any WriterControlling {
        try FileWriter(
            outputURL: self.urlProvider(kind),
            configuration: self.configuration,
            includeAudio: includeAudio,
            sourceFormatHint: sourceFormatHint,
            label: kind == .screen ? "screen" : "camera"
        )
    }
}

// MARK: - SourceFactory

/// Builds the capture sources for a session from the resolved plan.
///
/// This is a deviation from the prompt's listed seams (which named only encoder + writer
/// factories): sources cannot be constructor-injected into `RecordingSession` because they are
/// built from the resolved plan / devices INSIDE `start()` (`ScreenSource.init` needs the
/// `ResolvedRecordingPlan`). A factory seam keeps the mandated source fakes substitutable.
///
/// The product protocols already exist (`VideoFrameSource` / `AudioSampleSource`), so only the
/// factory + a live impl are added.
///
/// ### The camera is ONE object exposing both facets
/// `makeCamera` returns a single value typed `VideoFrameSource & AudioSampleSource` — `CameraSource`
/// is simultaneously the camera-video source AND the mic-audio source (the mic rides the camera's
/// `AVCaptureSession`). Returning one object preserves the single `events` stream and single
/// lifecycle that AC-12 relies on: `.cameraDisconnected` must tear down camera video AND end the
/// mic stream (which in turn ends screen-file audio) from that one events channel.
nonisolated protocol SourceFactory: Sendable {
    /// Builds the screen-capture source from the resolved plan.
    func makeScreenSource(
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration
    )
        -> any VideoFrameSource

    /// Builds the camera source (video + mic, one object). `micDevice == nil` → no audio samples.
    ///
    /// `cameraPlan` carries the resolved stabilization geometry (#297): the live factory wraps
    /// the camera in `StabilizingVideoSource` when `cameraPlan.stabilization` is present. This
    /// factory is the SINGLE decorator insertion point — `RecordingSession` wiring is identical
    /// with the toggle OFF (AC-3).
    func makeCameraSource(
        cameraDevice: CameraDevice,
        format: CameraFormat,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration,
        cameraPlan: ResolvedCameraPlan
    )
        -> any VideoFrameSource & AudioSampleSource
}

/// Live factory: builds real `ScreenSource` / `CameraSource` instances.
nonisolated struct LiveSourceFactory: SourceFactory {
    func makeScreenSource(
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration
    )
    -> any VideoFrameSource {
        ScreenSource(plan: plan, config: config)
    }

    func makeCameraSource(
        cameraDevice: CameraDevice,
        format: CameraFormat,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration,
        cameraPlan: ResolvedCameraPlan
    )
    -> any VideoFrameSource & AudioSampleSource {
        let camera = CameraSource(
            cameraDevice: cameraDevice,
            format: format,
            micDevice: micDevice,
            config: config,
            role: .record
        )
        // Stabilization OFF → the bare camera, byte-identical wiring to pre-#297 (AC-3).
        guard let stabilization = cameraPlan.stabilization else { return camera }
        return StabilizingVideoSource(
            wrapping: camera,
            stabilization: stabilization,
            planWidth: cameraPlan.width,
            stage: StabilizationRenderer(
                stabilization: stabilization,
                outputWidth: cameraPlan.width,
                outputHeight: cameraPlan.height
            )
        )
    }
}
