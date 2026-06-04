// RecordingSessionTests.swift
// OnsetTests
//
// Swift Testing suites for RecordingSession (#34).
//
// L2 — no hardware. Fakes: probe closure, EncoderFactory→FakeEncoder, WriterFactory→FakeWriter,
// SourceFactory→FakeSource/FakeCameraSource. Encoders are driven by emitting EncodedSamples
// directly through the fake's hook (a deliberate simplification of the prompt's "clockTick()" —
// the fake does not own a VTCompressionSession, so direct emission is the deterministic analogue).
//
// L5 — gated integration test (ONSET_RUN_L5_CAPTURE=1): a real RecordingSession runs ~5s and
// writes two files to a temp dir, asserting frame count > 0 and audio-sample count > 0.
//
// swiftlint:disable no_magic_numbers
// swiftlint:disable file_length
// swiftlint:disable function_body_length
// Rationale: synthetic CMSampleBuffer / timing literals are inherent test data (no_magic_numbers),
// the combined L2 + L5 suites make the file long (file_length), and the L5 integration test
// orchestrates a real session end-to-end (function_body_length). Same pattern as FileWriterTests.

import AVFoundation
import CoreMedia
@testable import Onset
import Testing

// MARK: - Fakes (encoder / source)

/// Records whether `start()` was ever called and emits EncodedSamples on demand.
private final class FakeEncoder: EncoderControlling, @unchecked Sendable {
    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var ingestedFrames = 0

    nonisolated let encodedSamples: AsyncStream<EncodedSample>
    private let samplesContinuation: AsyncStream<EncodedSample>.Continuation
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    /// When set, `start()` throws this (AC-6 path is normally surfaced by the probe, but the
    /// encoder can also fail).
    var startError: (any Error)?

    init() {
        let (samples, samplesContinuation) = AsyncStream.makeStream(of: EncodedSample.self)
        self.encodedSamples = samples
        self.samplesContinuation = samplesContinuation
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
    }

    func start() throws {
        self.startCalled = true
        if let startError { throw startError }
    }

    func ingest(_ frame: VideoFrame) {
        self.ingestedFrames += 1
    }

    func stop() {
        self.stopCalled = true
        self.samplesContinuation.finish()
        self.dropsContinuation.finish()
    }

    /// Test hook: emit an EncodedSample (analogue of the live encoder producing output).
    func emit(_ sample: EncodedSample) {
        self.samplesContinuation.yield(sample)
    }
}

private final class FakeEncoderFactory: EncoderFactory, @unchecked Sendable {
    let screenEncoder = FakeEncoder()
    let cameraEncoder = FakeEncoder()

    func makeEncoder(
        kind: RecordingPipelineKind,
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration,
        anchor: HostTimeAnchor
    )
    -> any EncoderControlling {
        switch kind {
        case .screen:
            self.screenEncoder

        case .camera:
            self.cameraEncoder
        }
    }
}

/// A fake screen source: drives frames/events on demand.
private final class FakeScreenSource: VideoFrameSource, @unchecked Sendable {
    nonisolated let frames: AsyncStream<VideoFrame>
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    nonisolated let events: AsyncStream<SourceEvent>
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    private(set) var startCalled = false
    private(set) var stopCalled = false

    init() {
        let (frames, framesContinuation) = AsyncStream.makeStream(of: VideoFrame.self)
        self.frames = frames
        self.framesContinuation = framesContinuation
        let (events, eventsContinuation) = AsyncStream.makeStream(of: SourceEvent.self)
        self.events = events
        self.eventsContinuation = eventsContinuation
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
    }

    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        self.startCalled = true
    }

    func stop() async {
        self.stopCalled = true
        self.framesContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }

    /// Test hook: emit a source event (e.g. `.displayDisconnected`).
    func emitEvent(_ event: SourceEvent) {
        self.eventsContinuation.yield(event)
    }
}

/// A fake camera source: video + mic, ONE object (both facets), as the live CameraSource is.
private final class FakeCameraSource: VideoFrameSource, AudioSampleSource, @unchecked Sendable {
    nonisolated let frames: AsyncStream<VideoFrame>
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    nonisolated let audioSamples: AsyncStream<AudioSample>
    private let audioContinuation: AsyncStream<AudioSample>.Continuation
    nonisolated let events: AsyncStream<SourceEvent>
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    private(set) var startCalled = false
    private(set) var stopCalled = false

    init() {
        let (frames, framesContinuation) = AsyncStream.makeStream(of: VideoFrame.self)
        self.frames = frames
        self.framesContinuation = framesContinuation
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioSample.self)
        self.audioSamples = audio
        self.audioContinuation = audioContinuation
        let (events, eventsContinuation) = AsyncStream.makeStream(of: SourceEvent.self)
        self.events = events
        self.eventsContinuation = eventsContinuation
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
    }

    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        self.startCalled = true
    }

    func stop() async {
        self.stopCalled = true
        // Mic stream ends with the camera (the mic rides the camera AVCaptureSession).
        self.framesContinuation.finish()
        self.audioContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }

    func emitEvent(_ event: SourceEvent) {
        self.eventsContinuation.yield(event)
    }

    func emitAudio(_ sample: AudioSample) {
        self.audioContinuation.yield(sample)
    }
}

private final class FakeSourceFactory: SourceFactory, @unchecked Sendable {
    let screenSource = FakeScreenSource()
    let cameraSource = FakeCameraSource()

    func makeScreenSource(plan: ResolvedRecordingPlan, config: RecordingConfiguration) -> any VideoFrameSource {
        self.screenSource
    }

    func makeCameraSource(
        cameraDevice: CameraDevice,
        format: CameraFormat,
        micDevice: MicrophoneDevice?,
        config: RecordingConfiguration
    )
    -> any VideoFrameSource & AudioSampleSource {
        self.cameraSource
    }
}

// MARK: - Writer fake (reuses the shape from DualFileOutputStageTests)

private final class SessionFakeWriter: WriterControlling, @unchecked Sendable {
    let kind: RecordingPipelineKind
    private(set) var startSourceTime: CMTime?
    private(set) var appendedVideo = 0
    private(set) var appendedAudio = 0
    private(set) var markFinishedCalled = false
    private(set) var finishCalled = false
    var finishResult: FinishResult

    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    init(kind: RecordingPipelineKind) {
        self.kind = kind
        self.finishResult = .completed(url: URL(fileURLWithPath: "/tmp/onset-session-fake-\(kind).mp4"))
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
    }

    func start(atSourceTime sourceTime: CMTime) throws {
        self.startSourceTime = sourceTime
    }

    func appendVideo(_ sample: EncodedSample) {
        self.appendedVideo += 1
    }

    func appendAudio(_ audio: RetimedAudioBuffer) {
        self.appendedAudio += 1
    }

    func markFinished() {
        self.markFinishedCalled = true
        self.dropsContinuation.finish()
    }

    func finish() async -> FinishResult {
        self.finishCalled = true
        return self.finishResult
    }
}

private final class SessionFakeWriterFactory: WriterFactory, @unchecked Sendable {
    let screenWriter = SessionFakeWriter(kind: .screen)
    let cameraWriter = SessionFakeWriter(kind: .camera)

    /// `true` once both writers have been created (their `start(atSourceTime:)` ran).
    var bothWritersCreated: Bool {
        self.screenWriter.startSourceTime != nil && self.cameraWriter.startSourceTime != nil
    }

    func makeWriter(
        kind: RecordingPipelineKind,
        sourceFormatHint: CMFormatDescription,
        includeAudio: Bool
    ) throws
    -> any WriterControlling {
        switch kind {
        case .screen:
            self.screenWriter

        case .camera:
            self.cameraWriter
        }
    }
}

// MARK: - Fixtures

private enum SessionFixtures {
    static func plan() -> ResolvedRecordingPlan {
        ResolvedRecordingPlan(
            displayID: 1,
            screenWidth: 1280,
            screenHeight: 720,
            screenFps: 60,
            cameraPlan: ResolvedCameraPlan(width: 1280, height: 720, fps: 30)
        )
    }

    static func display() -> Display {
        Display(displayID: 1, pixelWidth: 1280, pixelHeight: 720, refreshHz: 60)
    }

    static func cameraDevice() -> CameraDevice {
        CameraDevice(uniqueID: "fake-cam", formats: [self.cameraFormat()])
    }

    static func cameraFormat() -> CameraFormat {
        CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 30, maxFps: 30)
    }

    static func micDevice() -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: "fake-mic")
    }

    static func fullPermissions() -> EffectivePermissions {
        EffectivePermissions(screenAvailable: true, cameraAvailable: true, microphoneAvailable: true)
    }

    static func hevcFormat() throws -> CMFormatDescription {
        var desc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 1280,
            height: 720,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        guard status == noErr, let desc else { throw SessionTestError.failed(status) }
        return desc
    }

    static func encodedSample(ptsSeconds: Double) throws -> EncodedSample {
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let format = try hevcFormat()
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { throw SessionTestError.failed(status) }
        return EncodedSample(sampleBuffer: buffer, ptsHostTime: pts, isKeyframe: true)
    }
}

private enum SessionTestError: Error {
    case failed(OSStatus)
}

/// Builds a session wired with all fakes.
private func makeSession(
    encoders: FakeEncoderFactory,
    writers: SessionFakeWriterFactory,
    sources: FakeSourceFactory,
    probe: @escaping @Sendable () -> ProbeResult,
    includeCamera: Bool = true,
    includeMic: Bool = true
)
-> RecordingSession {
    RecordingSession(
        plan: SessionFixtures.plan(),
        display: SessionFixtures.display(),
        cameraDevice: includeCamera ? SessionFixtures.cameraDevice() : nil,
        cameraFormat: includeCamera ? SessionFixtures.cameraFormat() : nil,
        micDevice: includeMic ? SessionFixtures.micDevice() : nil,
        config: .mvpDefault,
        probe: probe,
        encoderFactory: encoders,
        writerFactory: writers,
        sourceFactory: sources
    )
}

/// Polls an actor-isolated condition with a bounded timeout — replaces fragile fixed sleeps.
private func eventually(
    timeoutMs: Int = 2000,
    _ condition: @Sendable () async -> Bool
) async
-> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return await condition()
}

// MARK: - AC-6 — probe blocks start

@Suite("RecordingSession — capability pre-flight (AC-6)")
struct RecordingSessionProbeTests {
    @Test("probe .noHardwareEncoder → start() throws, no writers created")
    func noHardwareEncoder_blocksStart() async throws {
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let noHWProbe: @Sendable () -> ProbeResult = { .noHardwareEncoder }
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: noHWProbe)

        // RecordingError's Equatable conformance is @MainActor-isolated (declared in an
        // extension), so it cannot satisfy the `#expect(throws:)` macro's Sendable+Equatable
        // bound — assert via do/catch instead.
        var isNoHardwareEncoder = false
        do {
            try await session.start(permissions: SessionFixtures.fullPermissions())
        } catch let error as RecordingError {
            if case .noHardwareEncoder = error { isNoHardwareEncoder = true }
        }
        #expect(isNoHardwareEncoder, "start() must throw .noHardwareEncoder")

        // No writer was created and no source/encoder was started.
        #expect(writers.screenWriter.startSourceTime == nil)
        #expect(writers.cameraWriter.startSourceTime == nil)
        #expect(!encoders.screenEncoder.startCalled)
        #expect(!sources.screenSource.startCalled)
    }
}

// MARK: - AC-7 — shared T0

@Suite("RecordingSession — shared T0 epoch (AC-7)")
struct RecordingSessionT0Tests {
    @Test("both writers get the IDENTICAL T0 in startSession")
    func bothWritersShareT0() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())

        // Drive one EncodedSample per pipeline → triggers lazy writer creation at T0.
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 3.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 7.0))

        let created = await eventually {
            writers.screenWriter.startSourceTime != nil && writers.cameraWriter.startSourceTime != nil
        }
        #expect(created, "both writers should have been created")

        let screenT0 = try #require(writers.screenWriter.startSourceTime)
        let cameraT0 = try #require(writers.cameraWriter.startSourceTime)
        #expect(CMTimeCompare(screenT0, cameraT0) == 0, "both writers must share the identical T0")

        _ = await session.stop()
    }
}

// MARK: - AC-9 — graceful stop

@Suite("RecordingSession — graceful stop (AC-9)")
struct RecordingSessionStopTests {
    @Test("stop flushes → markFinished → finish on both; result assembled")
    func stop_finalizesBoth() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        let result = await session.stop()

        #expect(encoders.screenEncoder.stopCalled)
        #expect(encoders.cameraEncoder.stopCalled)
        #expect(sources.screenSource.stopCalled)
        #expect(sources.cameraSource.stopCalled)
        #expect(writers.screenWriter.markFinishedCalled)
        #expect(writers.cameraWriter.markFinishedCalled)
        #expect(writers.screenWriter.finishCalled)
        #expect(writers.cameraWriter.finishCalled)
        #expect(result.screen != nil)
        #expect(result.camera != nil)
        #expect(result.outputURLs.count == 2)
    }

    @Test("degradedWarning true only when backpressure drops > 0")
    func degradedWarning_flag() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        // Emit a backpressure drop on the screen encoder → DropMonitor counts it.
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }
        // (No drops emitted → degradedWarning should be false.)

        let result = await session.stop()
        #expect(result.degradedWarning == false, "no backpressure drops → no warning (AC-8 policy)")
    }
}

// MARK: - AC-12 — revoke asymmetry

@Suite("RecordingSession — permission revoke (AC-12)")
struct RecordingSessionRevokeTests {
    @Test(".displayDisconnected → screen finalised, camera keeps recording")
    func displayDisconnect_finalizesScreenOnly() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Display disconnects → screen pipeline finalised; camera continues.
        sources.screenSource.emitEvent(.displayDisconnected)

        let screenFinalised = await eventually { writers.screenWriter.finishCalled }
        #expect(screenFinalised, "screen writer must be finalised on display disconnect")
        #expect(sources.screenSource.stopCalled)
        #expect(!writers.cameraWriter.finishCalled, "camera must keep recording")
        #expect(!sources.cameraSource.stopCalled, "camera source must not be stopped")

        // Camera still accepts video after the screen revoke.
        let beforeCameraVideo = writers.cameraWriter.appendedVideo
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 2.0))
        let cameraGotMore = await eventually { writers.cameraWriter.appendedVideo > beforeCameraVideo }
        #expect(cameraGotMore, "camera writer must still receive video")

        _ = await session.stop()
    }

    @Test(".cameraDisconnected → camera finalised + screen audio ends, screen video continues")
    func cameraDisconnect_finalizesCameraAndEndsScreenAudio() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Camera disconnects → camera pipeline finalised; the mic stream (riding the camera) ends.
        sources.cameraSource.emitEvent(.cameraDisconnected)

        let cameraFinalised = await eventually { writers.cameraWriter.finishCalled }
        #expect(cameraFinalised, "camera writer must be finalised on camera disconnect")
        #expect(sources.cameraSource.stopCalled)
        #expect(!writers.screenWriter.finishCalled, "screen must keep recording")
        #expect(!sources.screenSource.stopCalled, "screen source must not be stopped")

        // Screen video still flows after the camera revoke.
        let beforeScreenVideo = writers.screenWriter.appendedVideo
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 2.0))
        let screenGotMore = await eventually { writers.screenWriter.appendedVideo > beforeScreenVideo }
        #expect(screenGotMore, "screen writer must still receive video after camera revoke")

        _ = await session.stop()
    }
}

/// A Sendable wrapper providing a `.ok` probe closure built from a synthetic plan.
private struct SampleProbeOK {
    func callable() -> @Sendable () -> ProbeResult {
        { .ok(SessionFixtures.plan()) }
    }
}

// MARK: - L5 gated integration

/// Returns `true` when the L5 live recording test should run (real screen+camera+mic, hardware).
private func l5RecordingEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1"
}

@Suite("RecordingSession — L5 live recording", .serialized, .timeLimit(.minutes(2)))
struct RecordingSessionLiveTests {
    @Test(
        "real session records ~5s → two non-empty files (frames > 0, audio > 0)",
        .enabled(if: l5RecordingEnabled())
    )
    func liveRecording_producesTwoNonEmptyFiles() async throws {
        // Resolve a real display + camera + mic. Skipped silently if hardware is unavailable.
        let displays = try await DeviceDiscovery.displays(screenAuthorized: true)
        let display = try #require(displays.first, "no display available for L5")
        let cameras = DeviceDiscovery.cameras(cameraAuthorized: true)
        let camera = try #require(cameras.first, "no camera available for L5")
        let format = try CameraFormatSelector.pickBestFormat(from: camera.formats, minFps: 30)
        let mic = DeviceDiscovery.microphones(microphoneAuthorized: true).first

        let config = RecordingConfiguration.mvpDefault
        let plan = ResolvedRecordingPlan(
            displayID: display.displayID,
            screenWidth: display.pixelWidth.isMultiple(of: 2) ? display.pixelWidth : display.pixelWidth - 1,
            screenHeight: display.pixelHeight.isMultiple(of: 2) ? display.pixelHeight : display.pixelHeight - 1,
            screenFps: config.maxScreenFps,
            cameraPlan: ResolvedCameraPlan(
                width: Int(format.pixelWidth),
                height: Int(format.pixelHeight),
                fps: Int(format.maxFps)
            )
        )

        // Write to a temp dir, NOT ~/Movies.
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "RecordingSessionL5-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writerFactory = LiveWriterFactory(configuration: config) { kind in
            let suffix = kind == .screen ? "screen" : "camera"
            return tempDir.appending(path: "l5-\(suffix).mp4")
        }

        let session = RecordingSession(
            plan: plan,
            display: display,
            cameraDevice: camera,
            cameraFormat: format,
            micDevice: mic,
            config: config,
            writerFactory: writerFactory
        )

        try await session.start(permissions: EffectivePermissions(
            screenAvailable: true, cameraAvailable: true, microphoneAvailable: mic != nil
        ))
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 s
        let result = await session.stop()

        #expect(result.outputURLs.count == 2, "both files should be produced")
        for url in result.outputURLs {
            let exists = FileManager.default.fileExists(atPath: url.path)
            #expect(exists, "output file must exist: \(url.lastPathComponent)")
            let asset = AVURLAsset(url: url)

            // Guard against a TCC-denied / black / silent false-green: real samples must exist.
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let videoTrack = try #require(videoTracks.first, "no video track in \(url.lastPathComponent)")
            let frameCount = try self.countSamples(of: videoTrack, in: asset)
            #expect(frameCount > 0, "video track must contain > 0 frames: \(url.lastPathComponent)")

            // Audio fans out to BOTH files; when a mic was resolved, assert real audio samples
            // exist (a denied/silent capture would still produce an openable empty track).
            if mic != nil {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let audioTrack = try #require(audioTracks.first, "no audio track in \(url.lastPathComponent)")
                let audioCount = try self.countSamples(of: audioTrack, in: asset)
                #expect(audioCount > 0, "audio track must contain > 0 samples: \(url.lastPathComponent)")
            }
        }
    }

    /// Counts the readable sample buffers on one track (fresh reader per track — a reader is
    /// single-pass and one output per reader keeps the counts independent).
    private func countSamples(of track: AVAssetTrack, in asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil {
            count += 1
        }
        return count
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable function_body_length
// file_length stays disabled through EOF: it is a whole-file rule, so re-enabling it before the
// last line would re-trigger on the total count (same pattern as FileWriterTests).
