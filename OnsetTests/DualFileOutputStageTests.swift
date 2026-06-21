// DualFileOutputStageTests.swift
// OnsetTests
//
// Swift Testing suite for DualFileOutputStage (#33 audio fan-out + retiming, #34 dual-file output).
//
// L2 — no hardware. Uses a FakeWriter (records startSession T0, appendVideo, appendAudio buffer
// REFERENCES for identity assertions, markFinished, finish) and synthetic CMSampleBuffers.
//
// The AC-7 retiming red-green discriminator is the most important test here: it asserts the buffer
// handed to appendAudio has PTS == ptsHostTime after retiming, and FAILS if retiming is removed
// (the synthetic audio buffer is built with original PTS != ptsHostTime so the assertion is not
// vacuous).
//
// swiftlint:disable no_magic_numbers
// swiftlint:disable file_length
// swiftlint:disable function_body_length
// Rationale: synthetic CMSampleBuffer / timing literals are inherent test data (no_magic_numbers),
// the suite is long (file_length), and the audio-fixture builder is one CoreMedia transaction
// (function_body_length). Same pattern as FileWriterTests.

import AVFoundation
import CoreMedia
@testable import Onset
import os
import Testing

// MARK: - Helpers

/// A thread-safe boolean flag backed by `OSAllocatedUnfairLock`.
///
/// Replaces the bare `@unchecked Sendable` box pattern used in fault-suite callbacks:
/// the callback mutates the flag from `DualFileOutputStage`'s actor context while the
/// test reads it from its own async context, which is a formal data race under Swift 6
/// strict concurrency. Using `withLock` on both sides eliminates the race without
/// changing the observable test semantics.
private final class FlagBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func set() {
        self.lock.withLock { $0 = true }
    }

    var value: Bool {
        self.lock.withLock { $0 }
    }
}

// MARK: - Fakes

/// A fake WriterFactory that hands out preconfigured FakeWriters and records creation order.
private final class FakeWriterFactory: WriterFactory, @unchecked Sendable {
    /// Writers keyed by pipeline, created on demand. Pre-seeded so tests can inspect them.
    let screenWriter = FakeWriter(kind: .screen)
    let cameraWriter = FakeWriter(kind: .camera)
    private(set) var createdKinds: [RecordingPipelineKind] = []

    func makeWriter(
        kind: RecordingPipelineKind,
        sourceFormatHint: CMFormatDescription,
        includeAudio: Bool
    ) throws
    -> any WriterControlling {
        self.createdKinds.append(kind)
        switch kind {
        case .screen:
            self.screenWriter.includeAudio = includeAudio
            return self.screenWriter

        case .camera:
            self.cameraWriter.includeAudio = includeAudio
            return self.cameraWriter
        }
    }
}

/// A fake writer: records everything routed to it for assertions.
private final class FakeWriter: WriterControlling, @unchecked Sendable {
    let kind: RecordingPipelineKind
    var includeAudio = false

    /// The source time passed to start(atSourceTime:) — must be the verbatim session T0 (AC-7).
    private(set) var startSourceTime: CMTime?
    private(set) var appendedVideo: [EncodedSample] = []
    /// Captured buffer REFERENCES for fan-out identity assertions (===).
    private(set) var appendedAudioBuffers: [CMSampleBuffer] = []
    private(set) var markFinishedCalled = false
    private(set) var finishCalled = false

    /// The result `finish()` returns — set to `.failed` to test AC-9 independence.
    var finishResult: FinishResult

    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    nonisolated let faults: AsyncStream<Void>
    private let faultsContinuation: AsyncStream<Void>.Continuation

    init(kind: RecordingPipelineKind) {
        self.kind = kind
        self.finishResult = .completed(url: URL(fileURLWithPath: "/tmp/onset-fake-\(kind).mp4"))
        let (stream, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = stream
        self.dropsContinuation = continuation
        let (faultStream, faultContinuation) = AsyncStream.makeStream(of: Void.self)
        self.faults = faultStream
        self.faultsContinuation = faultContinuation
    }

    func start(atSourceTime sourceTime: CMTime) throws {
        self.startSourceTime = sourceTime
    }

    func appendVideo(_ sample: EncodedSample) {
        self.appendedVideo.append(sample)
    }

    func appendAudio(_ audio: RetimedAudioBuffer) {
        self.appendedAudioBuffers.append(audio.buffer)
    }

    func markFinished() {
        self.markFinishedCalled = true
        self.dropsContinuation.finish()
        self.faultsContinuation.finish()
    }

    func finish() async -> FinishResult {
        self.finishCalled = true
        return self.finishResult
    }

    /// Simulates a hard writer fault (as `AVAssetWriter.append()` returning `false`).
    func simulateFault() {
        self.faultsContinuation.yield(())
        self.faultsContinuation.finish()
    }
}

// MARK: - Synthetic buffers

private enum SampleFactory {
    /// Fixed session T0 (absolute host-time) used as the writers' startSession origin.
    static let sessionT0 = CMTime(value: 100_000, timescale: 600)

    /// Builds a minimal HEVC format description for the writer source hint.
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
        guard status == noErr, let desc else { throw StageTestError.formatFailed(status) }
        return desc
    }

    /// Builds an EncodedSample carrying a real HEVC format description (so the writer can be created).
    static func encodedSample(ptsSeconds: Double, kind: RecordingPipelineKind) throws -> EncodedSample {
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let format = try hevcFormat()
        var sampleBuffer: CMSampleBuffer?
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
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw StageTestError.sampleFailed(status) }
        // _ = kind is only used by callers for routing; encoded sample itself is kind-agnostic.
        _ = kind
        return EncodedSample(sampleBuffer: sampleBuffer, ptsHostTime: pts, isKeyframe: true)
    }

    /// Builds a multi-sample PCM audio buffer with a REAL block buffer (CMSampleBufferCreateCopyWithNewTiming
    /// requires a data-ready buffer). `originalFirstPTS` is set DIFFERENT from `ptsHostTime` so the
    /// retiming discriminator is not vacuous.
    static func audioSample(
        sampleCount: Int = 4,
        sampleRate: Double = 48000,
        originalFirstPTS: CMTime,
        ptsHostTime: CMTime
    ) throws
    -> AudioSample {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
        guard fmtStatus == noErr, let format else { throw StageTestError.formatFailed(fmtStatus) }

        // Real silent block buffer: sampleCount frames × 2 bytes/frame.
        let dataLength = sampleCount * 2
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
            throw StageTestError.blockBufferFailed(blockStatus)
        }
        // Zero the memory (silence).
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)

        // Per-sample timing: uniform duration, first PTS = originalFirstPTS, DTS invalid.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: originalFirstPTS,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [2],
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw StageTestError.sampleFailed(status) }
        return AudioSample(sampleBuffer: sampleBuffer, ptsHostTime: ptsHostTime)
    }
}

private enum StageTestError: Error {
    case formatFailed(OSStatus)
    case sampleFailed(OSStatus)
    case blockBufferFailed(OSStatus)
}

// MARK: - Stage factory helper

private func makeStage(
    factory: FakeWriterFactory,
    expected: Set<RecordingPipelineKind>,
    includeAudio: Bool,
    onAllWritersFaulted: @escaping @Sendable () async -> Void = {},
    onWriterFaulted: @escaping @Sendable (RecordingPipelineKind) async -> Void = { _ in }
)
    -> DualFileOutputStage
{ // swiftlint:disable:this opening_brace
    DualFileOutputStage(
        sessionT0: SampleFactory.sessionT0,
        expectedPipelines: expected,
        includeAudio: includeAudio,
        writerFactory: factory,
        onWriterCreated: { _ in },
        onAllWritersFaulted: onAllWritersFaulted,
        onWriterFaulted: onWriterFaulted
    )
}

// MARK: - Retiming (AC-7, #33)

@Suite("DualFileOutputStage — audio retiming (AC-7 / #33)")
struct DualFileOutputStageRetimingTests {
    /// THE red-green discriminator: after retiming, the buffer handed to appendAudio has
    /// PTS == ptsHostTime. Original PTS is deliberately != ptsHostTime, so this fails if the
    /// retiming is removed (the raw original PTS would be appended instead).
    @Test("retimed audio buffer PTS == ptsHostTime (fails if retiming removed)")
    func retiming_setsAbsoluteHostTimePTS() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.camera], includeAudio: true)

        // Create the camera writer first (so audio is delivered live, not buffered).
        let firstSample = try SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera)
        await stage.routeVideo(firstSample, from: .camera)

        let originalPTS = CMTime(value: 7777, timescale: 48000) // arbitrary, != ptsHostTime
        let ptsHostTime = CMTime(value: 222_000, timescale: 600)
        let audio = try SampleFactory.audioSample(originalFirstPTS: originalPTS, ptsHostTime: ptsHostTime)

        await stage.routeAudio(audio)

        let captured = try #require(factory.cameraWriter.appendedAudioBuffers.first)
        let retimedPTS = CMSampleBufferGetPresentationTimeStamp(captured)
        #expect(CMTimeCompare(retimedPTS, ptsHostTime) == 0, "retimed PTS must equal ptsHostTime")
        // Guard against a vacuous test: original PTS must differ from ptsHostTime.
        #expect(CMTimeCompare(originalPTS, ptsHostTime) != 0)
    }

    @Test("retiming preserves per-sample duration and keeps invalid DTS invalid")
    func retiming_preservesDurationAndDTS() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.camera], includeAudio: true)
        let firstSample = try SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera)
        await stage.routeVideo(firstSample, from: .camera)

        let originalPTS = CMTime(value: 5000, timescale: 48000)
        let ptsHostTime = CMTime(value: 300_000, timescale: 600)
        let audio = try SampleFactory.audioSample(originalFirstPTS: originalPTS, ptsHostTime: ptsHostTime)
        await stage.routeAudio(audio)

        let captured = try #require(factory.cameraWriter.appendedAudioBuffers.first)

        // Duration preserved (one grid step at 48 kHz).
        var timingCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            captured,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        #expect(countStatus == noErr)
        let emptyTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var timing = [CMSampleTimingInfo](repeating: emptyTiming, count: Int(timingCount))
        _ = CMSampleBufferGetSampleTimingInfoArray(
            captured,
            entryCount: timingCount,
            arrayToFill: &timing,
            entriesNeededOut: &timingCount
        )
        let first = try #require(timing.first)
        #expect(CMTimeCompare(first.duration, CMTime(value: 1, timescale: 48000)) == 0, "duration preserved")
        // DTS was invalid on input → must stay invalid (presentation order).
        #expect(!first.decodeTimeStamp.isValid, "invalid DTS must remain invalid")
    }
}

// MARK: - Fan-out (AC-7)

@Suite("DualFileOutputStage — fan-out identity & isolation (AC-7)")
struct DualFileOutputStageFanOutTests {
    @Test("SAME retimed buffer reference reaches BOTH writers")
    func fanOut_sameReferenceToBoth() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        // Create both writers so audio fans out live.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        let audio = try SampleFactory.audioSample(
            originalFirstPTS: CMTime(value: 1, timescale: 48000),
            ptsHostTime: CMTime(value: 200_000, timescale: 600)
        )
        await stage.routeAudio(audio)

        let screenBuf = try #require(factory.screenWriter.appendedAudioBuffers.first)
        let cameraBuf = try #require(factory.cameraWriter.appendedAudioBuffers.first)
        #expect(screenBuf === cameraBuf, "both writers must receive the SAME retimed buffer reference")
    }

    @Test("screen video never reaches the camera writer and vice versa")
    func routing_isolation() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: false)

        let screenSample = try SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen)
        let cameraSample = try SampleFactory.encodedSample(ptsSeconds: 2.0, kind: .camera)
        await stage.routeVideo(screenSample, from: .screen)
        await stage.routeVideo(cameraSample, from: .camera)

        #expect(factory.screenWriter.appendedVideo.count == 1)
        #expect(factory.cameraWriter.appendedVideo.count == 1)
        // Identity: the screen writer got the screen sample's buffer, not the camera's.
        #expect(factory.screenWriter.appendedVideo.first?.sampleBuffer === screenSample.sampleBuffer)
        #expect(factory.cameraWriter.appendedVideo.first?.sampleBuffer === cameraSample.sampleBuffer)
    }
}

// MARK: - Lazy writer + pending replay (AC-7)

@Suite("DualFileOutputStage — lazy writer & pending replay (AC-7)")
struct DualFileOutputStageLazyTests {
    @Test("writers start at the verbatim session T0 (AC-7)")
    func writerStartsAtT0() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: false)

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 5.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 9.0, kind: .camera), from: .camera)

        // Even though the first samples have different (and non-T0) PTS, both writers got T0.
        let screenStart = try #require(factory.screenWriter.startSourceTime)
        let cameraStart = try #require(factory.cameraWriter.startSourceTime)
        #expect(CMTimeCompare(screenStart, SampleFactory.sessionT0) == 0)
        #expect(CMTimeCompare(cameraStart, SampleFactory.sessionT0) == 0)
    }

    @Test("late-created writer replays identical early audio from the pending buffer")
    func lateWriter_replaysEarlyAudio() async throws {
        let factory = FakeWriterFactory()
        // Both pipelines expected; camera writer created first, screen writer created LATE.
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        // Camera writer exists; screen writer does not yet.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Early audio: camera gets it live; it is also buffered for the not-yet-created screen writer.
        let audio = try SampleFactory.audioSample(
            originalFirstPTS: CMTime(value: 3, timescale: 48000),
            ptsHostTime: CMTime(value: 210_000, timescale: 600)
        )
        await stage.routeAudio(audio)

        #expect(factory.cameraWriter.appendedAudioBuffers.count == 1)
        #expect(factory.screenWriter.appendedAudioBuffers.isEmpty, "screen writer not created yet")

        // Now create the screen writer late → it drains the pending buffer (identical early audio).
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)

        let cameraBuf = try #require(factory.cameraWriter.appendedAudioBuffers.first)
        let screenBuf = try #require(factory.screenWriter.appendedAudioBuffers.first)
        #expect(screenBuf === cameraBuf, "late writer must replay the IDENTICAL early audio buffer")
    }

    @Test("pending cap drops oldest (bounded)")
    func pendingCap_dropsOldest() async throws {
        let factory = FakeWriterFactory()
        // Two expected pipelines, neither writer created → all audio is buffered.
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        // Overflow the 256 cap: route 300 distinct audio buffers.
        let total = 300
        var firstBuffer: CMSampleBuffer?
        for index in 0..<total {
            let audio = try SampleFactory.audioSample(
                originalFirstPTS: CMTime(value: Int64(index), timescale: 48000),
                ptsHostTime: CMTime(value: Int64(200_000 + index), timescale: 600)
            )
            if index == 0 { firstBuffer = audio.sampleBuffer }
            await stage.routeAudio(audio)
        }

        // Now create both writers; each drains the (capped) pending list.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)

        // Bounded: at most the cap (256) buffers replayed per writer — oldest dropped.
        #expect(factory.cameraWriter.appendedAudioBuffers.count <= 256, "pending list must be bounded by the cap")
        // The earliest buffer was dropped (300 > 256), so it is not the first replayed buffer.
        let firstReplayed = factory.cameraWriter.appendedAudioBuffers.first
        let unwrappedFirst = try #require(firstBuffer)
        #expect(firstReplayed !== unwrappedFirst, "oldest buffer must have been dropped on overflow")
    }
}

// MARK: - Never-created revoke + warning throttle (#201)

@Suite("DualFileOutputStage — never-created revoke frees pending audio (#201)")
struct DualFileOutputStageDeadKindsTests {
    @Test("revoking a never-created pipeline releases pending audio (no unbounded growth)")
    func neverCreatedRevoke_freesPendingAudio() async throws {
        let factory = FakeWriterFactory()
        // Expected {screen, camera}; camera is revoked BEFORE any camera frame, screen survives.
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        // Screen writer exists; camera writer does NOT (no camera frame ever arrives).
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)

        // Early audio arrives while camera writer is still pending: screen gets it live, and it is
        // buffered for the not-yet-created camera writer.
        let early = try SampleFactory.audioSample(
            originalFirstPTS: CMTime(value: 1, timescale: 48000),
            ptsHostTime: CMTime(value: 210_000, timescale: 600)
        )
        await stage.routeAudio(early)
        #expect(factory.screenWriter.appendedAudioBuffers.count == 1, "survivor receives early audio")

        // Camera revoked before it ever created a writer (AC-12 camera-disconnect before first frame).
        await stage.finalizePipeline(.camera)

        // Flood far past the 256 cap AFTER the revoke. WITHOUT the fix the camera still blocks
        // `allWritersCreated()`, so every one of these is buffered and (past the cap) dropped,
        // driving `pendingAudioDropped` up. WITH the fix the effective expected set is satisfied
        // (only screen, which exists), so nothing is buffered and nothing is dropped.
        let flood = 300
        for index in 0..<flood {
            let audio = try SampleFactory.audioSample(
                originalFirstPTS: CMTime(value: Int64(index), timescale: 48000),
                ptsHostTime: CMTime(value: Int64(220_000 + index), timescale: 600)
            )
            await stage.routeAudio(audio)
        }

        // Red-green discriminator: zero drops means pending audio is no longer buffered for the
        // dead camera pipeline. Without the fix this would be flood - cap = 44.
        #expect(await stage.pendingAudioDropped == 0, "dead pipeline must not buffer/drop pending audio")
        // Audio-not-lost guarantee for the survivor: the early sample + all flood samples reached
        // the screen writer (1 early + 300 flood).
        #expect(
            factory.screenWriter.appendedAudioBuffers.count == 1 + flood,
            "survivor must receive every audio sample (early + post-revoke)"
        )
    }

    @Test("screen-only survives when camera was never expected (audio flows, nothing dropped)")
    func screenOnly_audioFlowsNoDrops() async throws {
        let factory = FakeWriterFactory()
        // Only screen expected — sanity that the effective-set logic does not regress the
        // single-pipeline case: pending audio is released once the screen writer exists.
        let stage = makeStage(factory: factory, expected: [.screen], includeAudio: true)

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        let total = 300
        for index in 0..<total {
            let audio = try SampleFactory.audioSample(
                originalFirstPTS: CMTime(value: Int64(index), timescale: 48000),
                ptsHostTime: CMTime(value: Int64(200_000 + index), timescale: 600)
            )
            await stage.routeAudio(audio)
        }

        #expect(await stage.pendingAudioDropped == 0, "single live pipeline must not buffer pending audio")
        #expect(factory.screenWriter.appendedAudioBuffers.count == total, "screen receives all audio")
    }

    @Test("drop counter is exact past the cap; warning is throttled (counter is the proxy)")
    func dropCounter_isExactPastCap() async throws {
        let factory = FakeWriterFactory()
        // Both expected, neither writer created → all audio is buffered, cap drops the oldest.
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        // Overflow by a known amount: cap + overflow buffers routed → exactly `overflow` drops.
        // The os.Logger warning throttle is not directly observable in a unit test (no logger seam
        // is injected — adding one would be production surface for a log line); `pendingAudioDropped`
        // is the proxy that proves no drop is lost while the warning itself is rate-limited.
        let cap = 256
        let overflow = 50
        for index in 0..<(cap + overflow) {
            let audio = try SampleFactory.audioSample(
                originalFirstPTS: CMTime(value: Int64(index), timescale: 48000),
                ptsHostTime: CMTime(value: Int64(200_000 + index), timescale: 600)
            )
            await stage.routeAudio(audio)
        }

        #expect(await stage.pendingAudioDropped == overflow, "every overflow sample is counted (none lost)")
    }
}

// MARK: - Finish independence (AC-9)

@Suite("DualFileOutputStage — finish independence (AC-9)")
struct DualFileOutputStageFinishTests {
    @Test("one writer .failed does not prevent the other's finish")
    func finishIndependence() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: false)

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Camera writer fails; screen writer completes.
        let failURL = URL(fileURLWithPath: "/tmp/onset-fake-camera.mp4")
        factory.cameraWriter.finishResult = .failed(url: failURL, error: StageTestError.sampleFailed(-1))

        let results = await stage.finishAll()

        #expect(factory.screenWriter.markFinishedCalled)
        #expect(factory.cameraWriter.markFinishedCalled)
        #expect(factory.screenWriter.finishCalled)
        #expect(factory.cameraWriter.finishCalled)

        let screen = try #require(results[.screen])
        let camera = try #require(results[.camera])
        if case .completed = screen {} else { Issue.record("screen should be .completed") }
        if case .failed = camera {} else { Issue.record("camera should be .failed") }
    }

    @Test("early-finalised pipeline keeps its captured result; other keeps recording (AC-12)")
    func finalizePipeline_isolates() async throws {
        let factory = FakeWriterFactory()
        let stage = makeStage(factory: factory, expected: [.screen, .camera], includeAudio: true)

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Finalise camera early (AC-12 camera-disconnect).
        await stage.finalizePipeline(.camera)
        #expect(factory.cameraWriter.markFinishedCalled)
        #expect(factory.cameraWriter.finishCalled)

        // Audio after finalize must NOT reach the finalised camera writer, but must reach screen.
        let beforeCamera = factory.cameraWriter.appendedAudioBuffers.count
        let audio = try SampleFactory.audioSample(
            originalFirstPTS: CMTime(value: 1, timescale: 48000),
            ptsHostTime: CMTime(value: 250_000, timescale: 600)
        )
        await stage.routeAudio(audio)
        #expect(factory.cameraWriter.appendedAudioBuffers.count == beforeCamera, "finalised camera gets no audio")
        #expect(factory.screenWriter.appendedAudioBuffers.count >= 1, "screen still records audio")

        // Screen video after finalize still reaches the screen writer.
        let beforeScreenVideo = factory.screenWriter.appendedVideo.count
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 2.0, kind: .screen), from: .screen)
        #expect(factory.screenWriter.appendedVideo.count == beforeScreenVideo + 1)

        // finishAll carries both results (camera from finalize time, screen from finish).
        let results = await stage.finishAll()
        #expect(results[.camera] != nil)
        #expect(results[.screen] != nil)
    }
}

// MARK: - Fail-fast helpers

/// Polls `condition` every 5 ms up to `timeoutMs`. Returns `true` as soon as the condition holds,
/// `false` if the deadline passes. Replaces fixed `Task.sleep` waits in fault-observer tests so
/// the suite is robust on slow CI runners where observer Tasks may take longer to be scheduled.
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

// MARK: - Fail-fast (#105)

@Suite("DualFileOutputStage — fail-fast on writer fault (#105)")
struct DualFileOutputStageFaultTests {
    // MARK: Both writers fault → callback fires

    @Test("all writers faulted → onAllWritersFaulted is called")
    func allWritersFaulted_callbackFires() async throws {
        let factory = FakeWriterFactory()
        let box = FlagBox()

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false
        ) { box.set() }

        // Trigger writer creation for both pipelines.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Fault both writers.
        factory.screenWriter.simulateFault()
        factory.cameraWriter.simulateFault()

        // Wait until the observer task inside DualFileOutputStage fires the callback.
        // `eventually` polls every 5 ms (up to 2 s) so the test is robust on slow CI runners
        // where scheduling a background Task may take significantly longer than 50 ms.
        let fired = await eventually { box.value }
        #expect(fired, "onAllWritersFaulted must fire when all writers are faulted")
    }

    // MARK: Only the created writer faults (second not yet created) → callback fires

    @Test("fault of the only CREATED writer, second not yet created → callback fires")
    func onlyCreatedWriterFaults_secondNotYetCreated_callbackFires() async throws {
        let factory = FakeWriterFactory()
        let box = FlagBox()

        // Both .screen and .camera are expected, but only .screen will be created.
        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false
        ) { box.set() }

        // Route a video sample only for .screen — camera writer is never created.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)

        // Fault the only created writer. liveKinds = created writers (not expectedPipelines),
        // so one created writer faulting satisfies the "all live writers faulted" condition.
        factory.screenWriter.simulateFault()

        // Poll until the callback fires — same rationale as allWritersFaulted_callbackFires.
        let fired = await eventually { box.value }
        #expect(fired && box.value, "onAllWritersFaulted must fire when the only created writer faults")
    }

    // MARK: Only one writer faults → callback does NOT fire

    @Test("one of two writers faulted → onAllWritersFaulted is NOT called")
    func oneWriterFaulted_callbackDoesNotFire() async throws {
        let factory = FakeWriterFactory()
        let box = FlagBox()

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false
        ) { box.set() }

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Fault only the screen writer.
        factory.screenWriter.simulateFault()

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!box.value, "onAllWritersFaulted must NOT fire when only one writer is faulted")
    }

    // MARK: Graceful finishAll does not fire callback

    @Test("graceful finishAll cancels observer tasks — callback does NOT fire")
    func finishAll_doesNotFireFaultCallback() async throws {
        let factory = FakeWriterFactory()
        let box = FlagBox()

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false
        ) { box.set() }

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Normal stop path — finishAll cancels observer tasks before markFinished.
        _ = await stage.finishAll()

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!box.value, "graceful finishAll must not trigger the fault callback")
    }
}

// MARK: - Partial-fault live-UI seam (#197)

@Suite("DualFileOutputStage — partial-fault live-UI seam (#197)")
struct DualFileOutputStagePartialFaultTests {
    // MARK: One writer faults → onWriterFaulted fires, onAllWritersFaulted does NOT

    @Test("one of two writers faults → onWriterFaulted(kind) fires, onAllWritersFaulted does NOT")
    func oneWriterFaults_onWriterFaultedFires_allWritersFaultedDoesNot() async throws {
        let factory = FakeWriterFactory()
        let allBox = FlagBox()
        let kindBox = OSAllocatedUnfairLock<RecordingPipelineKind?>(initialState: nil)

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false,
            onAllWritersFaulted: { allBox.set() },
            onWriterFaulted: { kind in kindBox.withLock { $0 = kind } }
        )

        // Create both writers.
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Fault only the screen writer.
        factory.screenWriter.simulateFault()

        // onWriterFaulted must fire with .screen.
        let firedKind = await eventually { kindBox.withLock { $0 } != nil }
        #expect(firedKind, "onWriterFaulted must fire when one of two writers faults")
        #expect(kindBox.withLock { $0 } == .screen, "onWriterFaulted must receive the faulted kind")

        // onAllWritersFaulted must NOT fire — the camera writer is still live.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!allBox.value, "onAllWritersFaulted must NOT fire when only one writer has faulted")
    }

    @Test("camera writer faults → onWriterFaulted(.camera) fires")
    func cameraWriterFaults_onWriterFaultedFiresWithCamera() async throws {
        let factory = FakeWriterFactory()
        let kindBox = OSAllocatedUnfairLock<RecordingPipelineKind?>(initialState: nil)

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false,
            onWriterFaulted: { kind in kindBox.withLock { $0 = kind } } // swiftlint:disable:this trailing_closure
        )

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        factory.cameraWriter.simulateFault()

        let fired = await eventually { kindBox.withLock { $0 } != nil }
        #expect(fired, "onWriterFaulted must fire when the camera writer faults")
        #expect(kindBox.withLock { $0 } == .camera)
    }

    // MARK: Both writers fault → onAllWritersFaulted fires (unchanged), onWriterFaulted NOT called

    @Test("both writers fault → onAllWritersFaulted fires, onWriterFaulted NOT called a second time")
    func bothWritersFault_onAllWritersFaultedFires_onWriterFaultedNotCalledSecondTime() async throws {
        let factory = FakeWriterFactory()
        let allBox = FlagBox()
        // Count how many times onWriterFaulted fires — must be at most once (for screen),
        // because the second fault takes the all-faulted branch and calls onAllWritersFaulted.
        let partialCount = OSAllocatedUnfairLock(initialState: 0)

        let stage = makeStage(
            factory: factory,
            expected: [.screen, .camera],
            includeAudio: false,
            onAllWritersFaulted: { allBox.set() },
            onWriterFaulted: { _ in partialCount.withLock { $0 += 1 } }
        )

        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .screen), from: .screen)
        try await stage.routeVideo(SampleFactory.encodedSample(ptsSeconds: 1.0, kind: .camera), from: .camera)

        // Fault screen first (partial), then camera (all-faulted).
        factory.screenWriter.simulateFault()
        // Wait for the partial callback before triggering the second fault, so the two
        // recordFault calls are serialised and we test the correct branch each time.
        _ = await eventually { partialCount.withLock { $0 } >= 1 }
        factory.cameraWriter.simulateFault()

        let allFired = await eventually { allBox.value }
        #expect(allFired, "onAllWritersFaulted must fire after both writers fault")
        // onWriterFaulted fires once (screen); the second fault goes to onAllWritersFaulted.
        #expect(partialCount.withLock { $0 } == 1, "onWriterFaulted must fire exactly once (for the partial fault)")
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable function_body_length
// file_length stays disabled through EOF (whole-file rule — same pattern as FileWriterTests).
