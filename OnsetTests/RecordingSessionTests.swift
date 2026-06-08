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
import os
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

    /// Test hook: emit a DropEvent on the drops stream (e.g. a backpressure drop for T1/Gap B).
    func emitDrop(_ event: DropEvent) {
        self.dropsContinuation.yield(event)
    }
}

private final class FakeEncoderFactory: EncoderFactory, @unchecked Sendable {
    let screenEncoder = FakeEncoder()
    let cameraEncoder = FakeEncoder()

    /// Captures the plan passed to the most-recent `makeEncoder` call (Gap A: verify AC-5 adoption).
    private(set) var lastPlan: ResolvedRecordingPlan?

    func makeEncoder(
        kind: RecordingPipelineKind,
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration,
        anchor: HostTimeAnchor
    )
    -> any EncoderControlling {
        self.lastPlan = plan
        switch kind {
        case .screen:
            return self.screenEncoder

        case .camera:
            return self.cameraEncoder
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
        config: RecordingConfiguration,
        targetFps: Int
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
    private(set) var finishCallCount = 0
    var finishResult: FinishResult

    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    nonisolated let faults: AsyncStream<Void>
    private let faultsContinuation: AsyncStream<Void>.Continuation

    init(kind: RecordingPipelineKind) {
        self.kind = kind
        self.finishResult = .completed(url: URL(fileURLWithPath: "/tmp/onset-session-fake-\(kind).mp4"))
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
        let (faults, faultsContinuation) = AsyncStream.makeStream(of: Void.self)
        self.faults = faults
        self.faultsContinuation = faultsContinuation
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

    func simulateFault() {
        self.faultsContinuation.yield(())
        self.faultsContinuation.finish()
    }

    func markFinished() {
        self.markFinishedCalled = true
        self.dropsContinuation.finish()
        self.faultsContinuation.finish()
    }

    func finish() async -> FinishResult {
        self.finishCalled = true
        self.finishCallCount += 1
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
        Display(displayID: 1, name: "Test Display", pixelWidth: 1280, pixelHeight: 720, refreshHz: 60)
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

    /// Builds a minimal PCM AudioSample (4 silent frames, 48 kHz, mono).
    static func audioSample(ptsSeconds: Double) throws -> AudioSample {
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard fmtStatus == noErr, let format else { throw SessionTestError.failed(fmtStatus) }
        let dataLength = 4 * 2 // 4 frames × 2 bytes/frame
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw SessionTestError.failed(blockStatus)
        }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 4,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [2],
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw SessionTestError.failed(status) }
        return AudioSample(sampleBuffer: sampleBuffer, ptsHostTime: pts)
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
    config: RecordingConfiguration = .mvpDefault,
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
        config: config,
        probe: probe,
        encoderFactory: encoders,
        writerFactory: writers,
        sourceFactory: sources
    )
}

/// Polls an actor-isolated condition with a bounded timeout — replaces fragile fixed sleeps.
/// 8s upper bound: eventually returns immediately once the condition holds, so this only
/// widens the failure-path budget — the success path is unaffected. Swift Testing runs @Test funcs
/// in parallel; under CI scheduler contention the stop()/stream await-chain can exceed a 2s
/// wall-clock deadline (issue #172). The coordinator stop-funnel is race-free (isStopping flips
/// synchronously before the first await), so a larger budget cannot mask a hang — it still fails, later.
private func eventually(
    timeoutMs: Int = 8000,
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

    @Test("probe .budgetExceeded → start() continues with reduced plan, writers created (AC-5)")
    func budgetExceeded_startsWithReducedPlan() async throws {
        // Reduced plan: lower resolution so the pixel budget is within limits.
        let reducedPlan = ResolvedRecordingPlan(
            displayID: 1,
            screenWidth: 854,
            screenHeight: 480,
            screenFps: 30,
            cameraPlan: nil
        )
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let probe: @Sendable () -> ProbeResult = { .budgetExceeded(suggested: reducedPlan) }
        // Session init uses SessionFixtures.plan() (1280×720) — the probe overrides it to reducedPlan.
        let session = makeSession(
            encoders: encoders,
            writers: writers,
            sources: sources,
            probe: probe,
            includeCamera: false // reducedPlan has no camera; disable camera device too
        )

        // Must NOT throw — AC-5 requires starting with the reduced profile.
        try await session.start(permissions: EffectivePermissions(
            screenAvailable: true,
            cameraAvailable: false,
            microphoneAvailable: false
        ))

        // The encoder was created using the reduced plan's dimensions, not the session's original.
        let lastPlan = try #require(encoders.lastPlan, "encoder must have been created")
        #expect(lastPlan == reducedPlan, "encoder must receive the budget-reduced plan (AC-5)")
        #expect(encoders.screenEncoder.startCalled, "screen encoder must have started")

        _ = await session.stop()
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

    @Test("degradedWarning false when no backpressure drops")
    func degradedWarning_false_whenNoDrops() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }
        // No drops emitted → degradedWarning should be false.

        let result = await session.stop()
        #expect(result.degradedWarning == false, "no backpressure drops → no warning (AC-8 policy)")
    }

    @Test("degradedWarning true when backpressure drops > 0")
    func degradedWarning_true_whenBackpressureDropped() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        // Emit a video frame to trigger writer creation.
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Emit a backpressure drop on the screen encoder → DropMonitor must count it.
        let dropPts = CMTime(seconds: 1.0, preferredTimescale: 600)
        encoders.screenEncoder.emitDrop(DropEvent(
            reason: .encoderBackpressureDrops, source: .encode, count: 1, detectedAt: dropPts
        ))

        let result = await session.stop()
        #expect(result.degradedWarning == true, "backpressure drop → degradedWarning must be true (AC-8)")
        #expect(result.drops.encoderBackpressureDrops > 0, "drop counter must reflect the emitted drop")
    }

    @Test("stop() is idempotent — second call returns the same result (Gap B)")
    func stop_idempotency_returnsSameResult() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Emit a real drop so the counters are non-zero — otherwise both calls returning zeroed
        // counters would pass vacuously even without the idempotency fix.
        let dropPts = CMTime(seconds: 1.0, preferredTimescale: 600)
        encoders.screenEncoder.emitDrop(DropEvent(
            reason: .encoderBackpressureDrops, source: .encode, count: 1, detectedAt: dropPts
        ))

        let first = await session.stop()
        let second = await session.stop()

        // Both calls must return the same outcome — field-by-field since FinishResult.failed carries
        // an existential Error which is not Equatable.
        #expect(first.outputURLs == second.outputURLs, "stop() must return identical URLs on re-entry")
        #expect(
            first.drops.encoderBackpressureDrops == second.drops.encoderBackpressureDrops,
            "stop() must return identical drop counters on re-entry"
        )
        #expect(
            first.degradedWarning == second.degradedWarning,
            "stop() must return identical degradedWarning on re-entry"
        )
        // The first result must have non-zero drops to confirm the test is non-vacuous.
        #expect(
            first.drops.encoderBackpressureDrops > 0,
            "drop counter must be non-zero (ensures non-vacuous comparison)"
        )
    }

    @Test("concurrent stop() calls run teardown once — same result, finishCallCount == 1")
    func stop_concurrent_runsOnce() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Emit a real drop so the counters are non-zero — vacuous equality would pass even without
        // the memoized-task fix (both returns of zeroed counters look "equal").
        let dropPts = CMTime(seconds: 1.0, preferredTimescale: 600)
        encoders.screenEncoder.emitDrop(DropEvent(
            reason: .encoderBackpressureDrops, source: .encode, count: 1, detectedAt: dropPts
        ))

        // Fire two concurrent stop() calls. Actor serialization guarantees the first to arrive
        // assigns stopTask before the second runs, so both observe the same Task and the teardown
        // body executes exactly once.
        async let stop1 = session.stop()
        async let stop2 = session.stop()
        let (first, second) = await (stop1, stop2)

        // Both results must be identical (same URLs, same drop counters, same warning flag).
        #expect(first.outputURLs == second.outputURLs, "concurrent stop() must return identical URLs")
        #expect(
            first.drops.encoderBackpressureDrops == second.drops.encoderBackpressureDrops,
            "concurrent stop() must return identical drop counters"
        )
        #expect(
            first.degradedWarning == second.degradedWarning,
            "concurrent stop() must return identical degradedWarning"
        )
        // Non-vacuous: the first result must carry the emitted drop.
        #expect(first.drops.encoderBackpressureDrops > 0, "drop counter must be non-zero")

        // Teardown ran exactly once — each writer's finish() was called once, not twice.
        #expect(writers.screenWriter.finishCallCount == 1, "screen writer finish() must be called exactly once")
        #expect(writers.cameraWriter.finishCallCount == 1, "camera writer finish() must be called exactly once")
    }

    @Test("stop() before start() returns .empty, no writers touched")
    func stop_beforeStart_returnsEmpty() async {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // stop() is called without a preceding start().
        let result = await session.stop()

        // Must return .empty — no pipelines were set up, no writers created.
        guard case .empty = result else {
            Issue.record("Expected .empty for stop-before-start, got \(result)")
            return
        }
        #expect(result.outputURLs.isEmpty, "no URLs expected when stop fires before start")
        #expect(result.degradedWarning == false, "no drops can have accumulated before start")
        // No writer interactions must have occurred.
        #expect(!writers.screenWriter.markFinishedCalled, "screen writer must not be touched")
        #expect(!writers.cameraWriter.markFinishedCalled, "camera writer must not be touched")
    }

    @Test("stop() before start() does not poison stopTask — subsequent start()→stop() runs teardown")
    func stop_beforeStart_doesNotPoisonStopTask() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // No-op stop before start.
        let noOpResult = await session.stop()
        guard case .empty = noOpResult else {
            Issue.record("Pre-start stop must return .empty")
            return
        }

        // Now start + emit a frame so a writer is created, then stop for real.
        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }

        let realResult = await session.stop()

        // The real stop must have run performStop — at least the screen writer was finished.
        #expect(writers.screenWriter.finishCalled, "real stop must call finish() on screen writer")
        // The result must not be .empty since a writer was created.
        guard case .completed = realResult else {
            Issue.record("Expected .completed after a real start()→stop(), got \(realResult)")
            return
        }
        #expect(realResult.screen != nil, "screen output must be present after a real session")
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

        // T2 setup: emit mic audio BEFORE disconnect so we can verify the count stops growing.
        // The audio pipeline routes mic → screen writer; wait until the screen writer sees it.
        let micAudio = try SessionFixtures.audioSample(ptsSeconds: 1.5)
        sources.cameraSource.emitAudio(micAudio)
        _ = await eventually { writers.screenWriter.appendedAudio > 0 }
        let audioBeforeDisconnect = writers.screenWriter.appendedAudio

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

        // T2: screen audio must NOT grow after camera disconnect. Settle on a second screen video
        // frame — this proves all pipeline events including the disconnect are ordered past the
        // settle point — then assert the audio count is unchanged.
        let beforeSecondFrame = writers.screenWriter.appendedVideo
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 3.0))
        _ = await eventually { writers.screenWriter.appendedVideo > beforeSecondFrame }
        #expect(
            writers.screenWriter.appendedAudio == audioBeforeDisconnect,
            "screen writer must not receive audio after camera (mic) disconnect (AC-12)"
        )

        _ = await session.stop()
    }

    @Test("early-finalised writer finish() is called exactly once (AC-12 double-finalize guard)")
    func earlyFinalize_finishCalledOnce() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Display disconnects → screen pipeline finalised early (revoke path).
        sources.screenSource.emitEvent(.displayDisconnected)
        _ = await eventually { writers.screenWriter.finishCalled }

        // stop() must NOT call finish() on the already-early-finalised screen writer again.
        _ = await session.stop()

        #expect(writers.screenWriter.finishCallCount == 1, "screen writer finish() must be called exactly once (AC-12)")
    }
}

/// A Sendable wrapper providing a `.ok` probe closure built from a synthetic plan.
private struct SampleProbeOK {
    func callable() -> @Sendable () -> ProbeResult {
        { .ok(SessionFixtures.plan()) }
    }
}

// MARK: - Revocation stream (#39 / AC-12 UI seam)

@Suite("RecordingSession — revocation stream (#39 / AC-12 UI seam)")
struct RecordingSessionRevocationStreamTests {
    @Test(".displayDisconnected → yields .sourceRevoked(.screen)")
    func displayDisconnected_yieldsScreenRevoked() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // Subscribe before start so no event is missed.
        let received: Task<RecordingRevocation?, Never> = Task {
            for await revocation in session.sourceRevocationStream {
                return revocation
            }
            return nil
        }

        try await session.start(permissions: SessionFixtures.fullPermissions())
        _ = await eventually { writers.bothWritersCreated }

        sources.screenSource.emitEvent(.displayDisconnected)

        let revocation = await received.value
        #expect(revocation == .sourceRevoked(.screen), "displayDisconnected must yield .sourceRevoked(.screen)")

        _ = await session.stop()
    }

    @Test(".cameraDisconnected → yields .sourceRevoked(.camera)")
    func cameraDisconnected_yieldsCameraRevoked() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        let received: Task<RecordingRevocation?, Never> = Task {
            for await revocation in session.sourceRevocationStream {
                return revocation
            }
            return nil
        }

        try await session.start(permissions: SessionFixtures.fullPermissions())
        _ = await eventually { writers.bothWritersCreated }

        sources.cameraSource.emitEvent(.cameraDisconnected)

        let revocation = await received.value
        #expect(revocation == .sourceRevoked(.camera), "cameraDisconnected must yield .sourceRevoked(.camera)")

        _ = await session.stop()
    }

    @Test("last pipeline finalised → yields .allVideoSourcesLost after the final .sourceRevoked")
    func lastPipelineFinalised_yieldsAllVideoSourcesLost() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // Collect all revocations until the stream closes (session.stop() finishes it).
        let allRevocations: Task<[RecordingRevocation], Never> = Task {
            var collected: [RecordingRevocation] = []
            for await revocation in session.sourceRevocationStream {
                collected.append(revocation)
            }
            return collected
        }

        try await session.start(permissions: SessionFixtures.fullPermissions())
        _ = await eventually { writers.bothWritersCreated }

        // Disconnect screen first (one pipeline remains after this).
        sources.screenSource.emitEvent(.displayDisconnected)
        _ = await eventually { writers.screenWriter.finishCalled }

        // Then disconnect camera — the last video pipeline gone → .allVideoSourcesLost must follow.
        sources.cameraSource.emitEvent(.cameraDisconnected)
        _ = await eventually { writers.cameraWriter.finishCalled }

        _ = await session.stop()

        let revocations = await allRevocations.value
        #expect(revocations.contains(.sourceRevoked(.screen)), "must include .sourceRevoked(.screen)")
        #expect(revocations.contains(.sourceRevoked(.camera)), "must include .sourceRevoked(.camera)")
        #expect(
            revocations.contains(.allVideoSourcesLost),
            "must include .allVideoSourcesLost after last pipeline gone"
        )
        // F2: .allVideoSourcesLost must arrive AFTER the final .sourceRevoked, not before.
        #expect(revocations.last == .allVideoSourcesLost, ".allVideoSourcesLost must be the last event yielded")
    }

    @Test("screen-only session: .displayDisconnected → [.sourceRevoked(.screen), .allVideoSourcesLost] in order")
    func screenOnlySession_displayDisconnected_yieldsRevocationsInOrder() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        // Screen-only: no camera device, no mic device. cameraDevice/cameraFormat nil → cameraPipeline
        // never created → cameraPipeline is nil from the start. When screenPipeline goes nil after
        // disconnect, the notifyRevocation check (screenPipeline==nil && cameraPipeline==nil) fires
        // immediately, emitting .allVideoSourcesLost as the very next event.
        let session = makeSession(
            encoders: encoders,
            writers: writers,
            sources: sources,
            probe: probe.callable(),
            includeCamera: false,
            includeMic: false
        )

        // Collect all revocations until the stream closes (session.stop() finishes it).
        let allRevocations: Task<[RecordingRevocation], Never> = Task {
            var collected: [RecordingRevocation] = []
            for await revocation in session.sourceRevocationStream {
                collected.append(revocation)
            }
            return collected
        }

        try await session.start(permissions: EffectivePermissions(
            screenAvailable: true,
            cameraAvailable: false,
            microphoneAvailable: false
        ))
        // Emit a sample so the screen writer is created (writer is lazy — created on first sample).
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }

        // Disconnect the sole video source — this is the last pipeline, so .allVideoSourcesLost
        // must follow immediately after .sourceRevoked(.screen).
        sources.screenSource.emitEvent(.displayDisconnected)
        _ = await eventually { writers.screenWriter.finishCalled }

        _ = await session.stop()

        let revocations = await allRevocations.value
        #expect(
            revocations == [.sourceRevoked(.screen), .allVideoSourcesLost],
            "screen-only disconnect must yield exactly [.sourceRevoked(.screen), .allVideoSourcesLost] in that order"
        )
    }

    // Camera-only session (screen mandatory per project scope): not constructible via makeSession —
    // the factory always provides a display and sets screenDevicePresent=true in resolvePlan.
    // makeSession has no includeScreen parameter to suppress the screen pipeline. Skipped.
}

// MARK: - UI state surface (#36/#37 — recordingStateStream + currentDrops)

@Suite("RecordingSession — UI state surface (#36/#37)")
struct RecordingSessionStateSurfaceTests {
    @Test("recordingStateStream forwards a .degraded transition from the monitor")
    func stateStream_forwardsDegradedTransition() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // Subscribe BEFORE start — the stream + continuation exist from init, the forwarding task
        // is spun in start(). The coordinator is the single consumer; here the test is that consumer.
        let received = Task { () -> RecordingState? in
            for await state in session.recordingStateStream {
                return state // first transition only
            }
            return nil
        }

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }

        // Emit enough backpressure drops to cross the degraded threshold for the configured window.
        // mvpDefault threshold is small; emit a burst at the same instant so the window trips.
        let dropPts = CMTime(seconds: 1.0, preferredTimescale: 600)
        let burst = RecordingConfiguration.mvpDefault.degradedBackpressureThreshold + 1
        encoders.screenEncoder.emitDrop(
            DropEvent(reason: .encoderBackpressureDrops, source: .encode, count: burst, detectedAt: dropPts)
        )

        let first = await received.value
        #expect(first == .degraded, "the first forwarded transition must be .degraded")

        _ = await session.stop()
    }

    @Test("currentDrops() reflects the monitor's snapshot")
    func currentDrops_reflectsSnapshot() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        // Before start, no monitor exists → zero counters.
        let beforeStart = await session.currentDrops()
        #expect(beforeStart.encoderBackpressureDrops == 0, "zero before start (no monitor yet)")

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }

        let dropPts = CMTime(seconds: 1.0, preferredTimescale: 600)
        encoders.screenEncoder.emitDrop(DropEvent(
            reason: .encoderBackpressureDrops, source: .encode, count: 3, detectedAt: dropPts
        ))

        // Poll currentDrops() until the asynchronously-ingested drop is reflected.
        let reflected = await eventually {
            await session.currentDrops().encoderBackpressureDrops == 3
        }
        #expect(reflected, "currentDrops() must reflect the monitor snapshot (3 backpressure drops)")

        _ = await session.stop()
    }

    @Test("recordingStateStream finishes after stop()")
    func stateStream_finishesAfterStop() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(encoders: encoders, writers: writers, sources: sources, probe: probe.callable())

        try await session.start(permissions: SessionFixtures.fullPermissions())
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.screenWriter.startSourceTime != nil }

        // Consume the stream to completion on a background task; it must terminate after stop().
        let drained = Task { () -> Bool in
            for await _ in session.recordingStateStream {}
            return true // returns only when the stream finishes
        }

        _ = await session.stop()

        let finished = await drained.value
        #expect(finished, "recordingStateStream must finish after stop() so the consumer's loop ends")
    }
}

// MARK: - Output directory creation

@Suite("RecordingSession — output directory")
struct RecordingSessionOutputDirectoryTests {
    @Test("start() creates the output directory when it does not exist")
    func start_createsOutputDirectory_whenAbsent() async throws {
        // UUID-unique path so parallel test runs do not collide.
        let tempDir = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "OnsetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Onset", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Precondition: directory must not exist before start().
        #expect(!FileManager.default.fileExists(atPath: tempDir.path(percentEncoded: false)))

        let mvp = RecordingConfiguration.mvpDefault
        let config = RecordingConfiguration(
            container: mvp.container,
            codec: mvp.codec,
            sampleEntry: mvp.sampleEntry,
            profileLevel: mvp.profileLevel,
            colorPrimaries: mvp.colorPrimaries,
            transferFunction: mvp.transferFunction,
            yCbCrMatrix: mvp.yCbCrMatrix,
            bitDepth: mvp.bitDepth,
            maxScreenFps: mvp.maxScreenFps,
            minCameraFps: mvp.minCameraFps,
            bitrateTable: mvp.bitrateTable,
            dataRateLimitsPeakMultiplier: mvp.dataRateLimitsPeakMultiplier,
            keyFrameIntervalSeconds: mvp.keyFrameIntervalSeconds,
            allowFrameReordering: mvp.allowFrameReordering,
            pixelFormatPreference: mvp.pixelFormatPreference,
            audioSampleRate: mvp.audioSampleRate,
            audioChannelCount: mvp.audioChannelCount,
            audioBitrate: mvp.audioBitrate,
            movieFragmentInterval: mvp.movieFragmentInterval,
            degradedBackpressureThreshold: mvp.degradedBackpressureThreshold,
            degradedWindowSeconds: mvp.degradedWindowSeconds,
            budgetCap: mvp.budgetCap,
            outputDirectory: tempDir
        )

        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(
            encoders: encoders,
            writers: writers,
            sources: sources,
            probe: probe.callable(),
            config: config
        )

        try await session.start(permissions: SessionFixtures.fullPermissions())

        #expect(
            FileManager.default.fileExists(atPath: tempDir.path(percentEncoded: false)),
            "start() must create the output directory before constructing any FileWriter"
        )

        _ = await session.stop()
    }
}

// MARK: - L5 gated integration

/// Returns `true` when the L5 live recording test should run (real screen+camera+mic, hardware).
private func l5RecordingEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1"
}

/// Returns `true` when the L5 test should preserve its output files after the run.
/// Set `ONSET_L5_KEEP_OUTPUT=1` in the scheme environment before running.
private func l5KeepOutput() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_L5_KEEP_OUTPUT"] == "1"
}

/// Recording duration in seconds for L5 tests.
///
/// Reads `ONSET_L5_DURATION_SECONDS` from the environment. Falls back to 5 when
/// unset or empty (silent). Logs a warning and falls back to 5 when the value is set
/// but is not a positive integer (e.g. "30s", "0") so the misconfiguration is visible.
/// The suite `.timeLimit(.minutes(10))` is the hard ceiling — set a duration well
/// below ~590 s or the test will time out.
private func l5DurationSeconds() -> Int {
    guard let raw = ProcessInfo.processInfo.environment["ONSET_L5_DURATION_SECONDS"],
          !raw.isEmpty
    else { return 5 }
    guard let parsed = Int(raw), parsed > 0 else {
        l5Logger.warning("ONSET_L5_DURATION_SECONDS='\(raw)' is not a positive integer — using default 5s")
        return 5
    }
    return parsed
}

/// Case-insensitive substring filter applied to discovered camera display names.
///
/// Reads `ONSET_L5_CAMERA_NAME` from the environment. When unset or empty the
/// first discovered camera is used (same behaviour as before this knob existed).
/// When set but no camera name contains the substring, the test fails via `try #require`.
/// Example: `ONSET_L5_CAMERA_NAME=MX Brio` pins the Logitech MX Brio.
private func l5CameraName() -> String? {
    guard let raw = ProcessInfo.processInfo.environment["ONSET_L5_CAMERA_NAME"],
          !raw.isEmpty
    else { return nil }
    return raw
}

/// Picks a camera from `cameras` whose `AVCaptureDevice.localizedName` contains
/// `nameFilter` (case-insensitive). Returns `nil` when no match is found — the caller
/// must handle this (typically via `try #require`) so a mismatched filter fails loudly
/// instead of silently verifying the wrong device.
///
/// The filter uses `AVCaptureDevice` directly for the name comparison because
/// `CameraDevice` stores only `uniqueID`/`formats` (no display name — PII policy).
/// The device name is used transiently for matching only and is never logged.
///
/// - Parameters:
///   - cameras: Pre-enumerated `CameraDevice` snapshots (same list as the session uses).
///   - nameFilter: Case-insensitive substring to match against `localizedName`.
/// - Returns: The first matching camera, or `nil` when no match is found.
///   Logs whether the filter matched (boolean flag only — no name in the log).
private func pickCamera(from cameras: [CameraDevice], nameFilter: String) -> CameraDevice? {
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    let matchedID = discoverySession.devices
        .first { $0.localizedName.localizedCaseInsensitiveContains(nameFilter) }
        .map(\.uniqueID)

    if let matchedID, let camera = cameras.first(where: { $0.uniqueID == matchedID }) {
        l5Logger.notice("L5_CAMERA_PICK name_matched=true")
        return camera
    }
    l5Logger.notice("L5_CAMERA_PICK name_matched=false")
    return nil
}

nonisolated private let l5Logger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingSessionL5Tests"
)

@Suite("RecordingSession — L5 live recording", .serialized, .timeLimit(.minutes(10)))
struct RecordingSessionLiveTests {
    @Test(
        "real session records ~5s → two non-empty files (frames > 0, audio > 0)",
        .enabled(if: l5RecordingEnabled())
    )
    func liveRecording_producesTwoNonEmptyFiles() async throws {
        try await self.runLiveRecordingSession(includeScreen: true, outputSubdir: "dual")
    }

    @Test(
        "camera-only session records → one non-empty camera file (frames > 0, audio > 0)",
        .enabled(if: l5RecordingEnabled())
    )
    func liveRecording_cameraOnly_producesCameraFile() async throws {
        try await self.runLiveRecordingSession(includeScreen: false, outputSubdir: "cameraOnly")
    }

    // MARK: - Shared helper

    /// Runs a live recording session for the configured duration and asserts non-empty output.
    ///
    /// When `includeScreen` is `true` the session receives both screen and camera
    /// permissions, producing two output files. When `false` only the camera permission
    /// is granted, producing a single camera file (audio included when a mic is present).
    ///
    /// The `outputSubdir` value scopes kept output under `OnsetL5Acceptance/<subdir>/`
    /// so dual and camera-only runs do not clobber each other.
    private func runLiveRecordingSession(includeScreen: Bool, outputSubdir: String) async throws {
        let mode = includeScreen ? "dual" : "cameraOnly"

        // Resolve a real display + camera + mic. Skipped silently if hardware is unavailable.
        let displays = try await DeviceDiscovery.displays(screenAuthorized: true)
        let display = try #require(displays.first, "no display available for L5")
        let cameras = DeviceDiscovery.cameras(cameraAuthorized: true)
        let camera: CameraDevice = if let nameFilter = l5CameraName() {
            try #require(pickCamera(from: cameras, nameFilter: nameFilter), "no camera available for L5")
        } else {
            try #require(cameras.first, "no camera available for L5")
        }
        let format = try CameraFormatSelector.pickBestFormat(from: camera.formats, minFps: 30)
        let mic = DeviceDiscovery.microphones(microphoneAuthorized: true).first

        let duration = l5DurationSeconds()
        let camW = format.pixelWidth
        let camH = format.pixelHeight
        let camFps = Int(format.maxFps)
        l5Logger.notice("L5_RUN_START mode=\(mode) dur_s=\(duration) cam_w=\(camW) cam_h=\(camH) cam_fps=\(camFps)")

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
        // When ONSET_L5_KEEP_OUTPUT=1 use a stable subdir path so files survive the test run.
        let keepOutput = l5KeepOutput()
        let tempDir: URL
        if keepOutput {
            tempDir = FileManager.default.temporaryDirectory
                .appending(path: "OnsetL5Acceptance", directoryHint: .isDirectory)
                .appending(path: outputSubdir, directoryHint: .isDirectory)
            // Remove any leftover from a previous run then create clean.
            try? FileManager.default.removeItem(at: tempDir)
        } else {
            tempDir = FileManager.default.temporaryDirectory
                .appending(path: "RecordingSessionL5-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            if !keepOutput { try? FileManager.default.removeItem(at: tempDir) }
        }

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
            screenAvailable: includeScreen, cameraAvailable: true, microphoneAvailable: mic != nil
        ))
        try await Task.sleep(for: .seconds(l5DurationSeconds()))
        let result = await session.stop()

        l5Logger.notice("L5_RUN_END mode=\(mode)")

        if keepOutput {
            for url in result.outputURLs {
                l5Logger.info("L5_KEEP_OUTPUT path=\(url.path(percentEncoded: false))")
            }
        }

        let expectedCount = includeScreen ? 2 : 1
        #expect(result.outputURLs.count == expectedCount, "expected \(expectedCount) output file(s)")
        for url in result.outputURLs {
            let exists = FileManager.default.fileExists(atPath: url.path)
            #expect(exists, "output file must exist: \(url.lastPathComponent)")
            let asset = AVURLAsset(url: url)

            // Guard against a TCC-denied / black / silent false-green: real samples must exist.
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let videoTrack = try #require(videoTracks.first, "no video track in \(url.lastPathComponent)")
            let frameCount = try self.countSamples(of: videoTrack, in: asset)
            #expect(frameCount > 0, "video track must contain > 0 frames: \(url.lastPathComponent)")

            // Audio fans out to BOTH files in dual mode; in camera-only the single file carries
            // audio. When a mic was resolved, assert real audio samples exist (a denied/silent
            // capture would still produce an openable empty track).
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

// MARK: - Fail-fast on writer fault (AC-13 / #105)

@Suite("RecordingSession — fail-fast on writer fault")
struct RecordingSessionFaultTests {
    @Test("all writers faulted mid-recording → session stops itself")
    func allWritersFaultedMidRecording_sessionStopsItself() async throws {
        let probe = SampleProbeOK()
        let encoders = FakeEncoderFactory()
        let writers = SessionFakeWriterFactory()
        let sources = FakeSourceFactory()
        let session = makeSession(
            encoders: encoders,
            writers: writers,
            sources: sources,
            probe: probe.callable()
        )

        try await session.start(permissions: SessionFixtures.fullPermissions())

        // Drive one sample per pipeline so both writers are created.
        try encoders.screenEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        try encoders.cameraEncoder.emit(SessionFixtures.encodedSample(ptsSeconds: 1.0))
        _ = await eventually { writers.bothWritersCreated }

        // Fault both writers — the session's onAllWritersFaulted callback calls stop().
        writers.screenWriter.simulateFault()
        writers.cameraWriter.simulateFault()

        // Session must stop itself without an explicit session.stop() call.
        let stopped = await eventually {
            sources.screenSource.stopCalled && sources.cameraSource.stopCalled
        }
        #expect(stopped, "session must stop all sources when all writers fault")
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable function_body_length
// file_length stays disabled through EOF: it is a whole-file rule, so re-enabling it before the
// last line would re-trigger on the total count (same pattern as FileWriterTests).
