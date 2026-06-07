// FileWriterTests.swift
// OnsetTests
//
// Swift Testing suite for FileWriter (Storage layer, #32).
//
// Tests:
//   L2 — unit (no hardware):
//     - video input has nil outputSettings (passthrough mode).
//     - audio input carries AAC output settings.
//     - movieFragmentInterval is set before startWriting (testable via a subclass seam).
//     - appendVideo with isReadyForMoreMediaData == false → emits DropEvent.
//   L5 — integration (real VideoEncoder + real AVAssetWriter, hardware required):
//     - full pipeline: VideoEncoder → FileWriter → AVAsset hvc1 track.
//
// The nil-hint negative case (sourceFormatHint required for MP4) is NOT a kept test: an
// AVAssetWriter passthrough input with a nil hint crashes at add(input:) with an uncaught
// NSInvalidArgumentException, which terminates the test host and cannot be a green assertion
// without an ObjC @try/@catch shim. The empirical finding is documented in FileWriter's
// type-level doc (init contract) and was verified by a throwaway probe run on 2026-06-04.
//
// The L5 tests are gated on ONSET_RUN_L5_ENCODE=1 (same env var as VideoEncoder L5).
//
// swiftlint:disable no_magic_numbers
// swiftlint:disable file_length
// swiftlint:disable function_body_length
// Rationale: combined L2+L5 in one file (same pattern as VideoEncoderTests.swift).
// L5 integration tests are necessarily long — they orchestrate a real encoder + muxer pipeline.

import AVFoundation
import CoreMedia
import CoreVideo
@testable import Onset
import Testing
import VideoToolbox

// MARK: - Test helpers

private let testFps = 30
private let testWidth: Int32 = 1280
private let testHeight: Int32 = 720

private func fileWriterL5Enabled() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_RUN_L5_ENCODE"] == "1"
}

/// Build a minimal `CMFormatDescription` for 1280×720 HEVC.
/// Used as the sourceFormatHint in FileWriter's init.
private func makeHEVCFormatDescription() throws -> CMFormatDescription {
    var desc: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecType_HEVC,
        width: testWidth,
        height: testHeight,
        extensions: nil,
        formatDescriptionOut: &desc
    )
    guard status == noErr, let desc else {
        throw TestError.formatDescriptionFailed(status)
    }
    return desc
}

/// Fixed anchor at 100 s on a 600-timescale clock.
private func makeFixedAnchor() -> HostTimeAnchor {
    HostTimeAnchor(anchorTime: CMTime(value: 60000, timescale: 600))
}

private func makeEncoderSettings() -> VTEncoderSettings {
    EncoderConfigBuilder.build(
        config: .mvpDefault,
        width: Int(testWidth),
        height: Int(testHeight),
        fps: testFps
    )
}

/// Allocates an IOSurface-backed 420v pixel buffer for encoding tests.
private func makePixelBuffer(
    width: Int = Int(testWidth),
    height: Int = Int(testHeight)
)
-> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        preconditionFailure("pixel buffer alloc failed: \(status)")
    }
    return buffer
}

/// Fills a pixel buffer with a solid grey (Y=128, UV=128).
private func fillSolidGrey(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
    let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    memset(lumaBase, 128, lumaHeight * lumaBytesPerRow)

    guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
    let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
    let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    memset(chromaBase, 128, chromaHeight * chromaBytesPerRow)
}

// MARK: - StubWriterInput

/// A test stub for `WriterInputSeam` that can simulate not-ready state.
private final class StubWriterInput: WriterInputSeam, @unchecked Sendable {
    var ready: Bool
    /// Value returned by `append()` — set to `false` to simulate a faulted writer
    /// (a real `AVAssetWriterInput.append()` returns `false` only after the writer faults).
    var appendReturnValue: Bool
    private(set) var appendedBuffers: [CMSampleBuffer] = []

    init(ready: Bool = true, appendReturnValue: Bool = true) {
        self.ready = ready
        self.appendReturnValue = appendReturnValue
    }

    nonisolated var isReadyForMoreMediaData: Bool {
        self.ready
    }

    @discardableResult
    nonisolated func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.appendedBuffers.append(sampleBuffer)
        return self.appendReturnValue
    }
}

// MARK: - FileWriterInputSettingsTests (L2)

// These tests inspect the AVAssetWriterInput configuration produced by FileWriter.init.
// They require a real AVAssetWriter (no hardware), so they run synchronously without a device.
// The L5 gate is NOT required here.
//
// The tests create a file URL in the temp directory; no actual data is written (startWriting
// is not called).

@Suite("FileWriter — input configuration (L2)")
struct FileWriterInputSettingsTests {
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "FileWriterInputSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test("video input has nil outputSettings (passthrough)")
    func videoInput_nilOutputSettings() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )
        // isVideoPassthrough == true confirms outputSettings == nil (no re-encode).
        let isPassthrough = await writer.isVideoPassthroughForTesting
        #expect(isPassthrough)
    }

    @Test("movieFragmentInterval is configured before startWriting")
    func movieFragmentInterval_setBeforeStart() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test-fragment.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        // The interval must be set on the writer at init time (before startWriting) so that
        // crash recovery (#34) can salvage already-flushed fragments.
        let interval = await writer.movieFragmentIntervalForTesting
        let expected = CMTime(
            seconds: RecordingConfiguration.mvpDefault.movieFragmentInterval,
            preferredTimescale: 600
        )
        #expect(CMTimeCompare(interval, expected) == 0)
    }

    @Test("audio input carries AAC output settings")
    func audioInput_hasAACSettings() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: true,
            sourceFormatHint: hint
        )
        let snapshot = try #require(await writer.audioSettingsForTesting)

        let formatID = try #require(snapshot.formatID)
        #expect(formatID == kAudioFormatMPEG4AAC)

        let sampleRate = try #require(snapshot.sampleRate)
        #expect(sampleRate == RecordingConfiguration.mvpDefault.audioSampleRate)

        let channels = try #require(snapshot.channelCount)
        #expect(channels == RecordingConfiguration.mvpDefault.audioChannelCount)

        let bitrate = try #require(snapshot.bitrate)
        #expect(bitrate == RecordingConfiguration.mvpDefault.audioBitrate)
    }

    @Test("includeAudio: false → no audio input added")
    func noAudio_audioInputIsNil() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )
        let hasAudio = await writer.hasAudioInputForTesting
        #expect(!hasAudio)
    }
}

// MARK: - FileWriterDropTests (L2, stub seam)

@Suite("FileWriter — appendVideo backpressure drop (L2)")
struct FileWriterDropTests {
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "FileWriterDropTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Makes a minimal `EncodedSample` for testing (no real compressed data needed).
    private func makeEncodedSample(ptsSeconds: Double) throws -> EncodedSample {
        // Build a minimal CMSampleBuffer with the given PTS. No actual encoded data —
        // the test only exercises the readiness gate, not the buffer content.
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(testFps)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let hint = try makeHEVCFormatDescription()
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: hint,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw TestError.sampleBufferFailed(status)
        }
        return EncodedSample(sampleBuffer: sampleBuffer, ptsHostTime: pts, isKeyframe: true)
    }

    @Test("appendVideo with not-ready input → emits DropEvent(.encoderBackpressureDrops)")
    func appendVideo_notReady_emitsDropEvent() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        // Inject a not-ready stub so the writer believes disk backpressure is active.
        let stub = StubWriterInput(ready: false)
        await writer.injectVideoInputForTesting(stub)

        // Subscribe to drops BEFORE triggering the drop.
        let dropCollector = Task { () -> [DropEvent] in
            var events: [DropEvent] = []
            for await event in await writer.drops {
                events.append(event)
                break // collect just the first event
            }
            return events
        }

        let sample = try self.makeEncodedSample(ptsSeconds: 1.0)
        await writer.appendVideo(sample)

        // Finish the drops stream so the collector's `for await` loop can terminate.
        // `finishDropsForTesting()` is used instead of the full markFinished/finish
        // lifecycle because calling `AVAssetWriter.finishWriting()` without a prior
        // `startWriting()` crashes the writer.
        await writer.finishDropsForTesting()

        let events = await dropCollector.value
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.reason == .encoderBackpressureDrops)
        #expect(event.count == 1)
        #expect(event.detectedAt == CMTime(seconds: 1.0, preferredTimescale: 600))
    }

    @Test("appendVideo with not-ready input → buffer is NOT appended")
    func appendVideo_notReady_bufferNotAppended() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        let stub = StubWriterInput(ready: false)
        await writer.injectVideoInputForTesting(stub)

        let sample = try self.makeEncodedSample(ptsSeconds: 1.0)
        await writer.appendVideo(sample)

        // The stub must record zero appended buffers.
        #expect(stub.appendedBuffers.isEmpty)
    }

    @Test("appendVideo with ready input but append()==false → NO DropEvent, writer becomes faulted")
    func appendVideo_appendReturnsFalse_faultsWithoutDropEvent() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        // Ready == true (so the backpressure path is excluded) but append() returns false,
        // simulating a faulted AVAssetWriter. This is a hard failure, not backpressure.
        let stub = StubWriterInput(ready: true, appendReturnValue: false)
        await writer.injectVideoInputForTesting(stub)

        // Collect every drop event emitted; expect none.
        let dropCollector = Task { () -> [DropEvent] in
            var events: [DropEvent] = []
            for await event in await writer.drops {
                events.append(event)
            }
            return events
        }

        // First append faults the writer (append()==false). A second append exercises the
        // post-fault short-circuit — the named regression: a faulted writer must NOT have its
        // subsequent calls misclassified as backpressure drops.
        let sample = try self.makeEncodedSample(ptsSeconds: 1.0)
        await writer.appendVideo(sample)
        await writer.appendVideo(sample)

        // Finish the stream so the collector terminates (no events should have arrived).
        await writer.finishDropsForTesting()

        let events = await dropCollector.value
        #expect(events.isEmpty, "hard writer failure must not emit a backpressure DropEvent")

        let faulted = await writer.isFaultedForTesting
        #expect(faulted, "append()==false must mark the writer faulted")
    }

    @Test("append()==false → faults emits exactly one value, then finishes")
    func appendReturnsFalse_faultsEmitsOne() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test-faults-one.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        let stub = StubWriterInput(ready: true, appendReturnValue: false)
        await writer.injectVideoInputForTesting(stub)

        // Collect every value emitted by the faults stream. The stream self-terminates
        // after the first fault (yield + finish), so the task exits naturally.
        let faultsCollector = Task { () -> [Void] in
            var values: [Void] = []
            for await _ in writer.faults {
                values.append(())
            }
            return values
        }

        let sample = try self.makeEncodedSample(ptsSeconds: 1.0)
        await writer.appendVideo(sample)

        let values = await faultsCollector.value
        #expect(values.count == 1, "faults must emit exactly one value on first append failure")
    }

    @Test("markFinished() → faults finishes WITHOUT emitting a value")
    func markFinished_faultsFinishesWithoutYield() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = self.tempDir.appending(path: "test-faults-empty.mp4")
        let hint = try makeHEVCFormatDescription()
        let writer = try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        // start() puts AVAssetWriter into .writing state — required before markFinished() so
        // that rawVideoInput.markAsFinished() is a defined operation. Without startWriting(),
        // markAsFinished() on an unstarted AVAssetWriterInput produces undefined behavior on
        // some AVFoundation versions (hangs the actor, preventing faultsContinuation.finish()).
        try await writer.start(atSourceTime: .zero)

        // Collect from faults before calling markFinished so we don't miss any early yield.
        let faultsCollector = Task { () -> [Void] in
            var values: [Void] = []
            for await _ in writer.faults {
                values.append(())
            }
            return values
        }

        // markFinished() calls faultsContinuation.finish() without yield — graceful teardown.
        await writer.markFinished()

        let values = await faultsCollector.value
        #expect(values.isEmpty, "markFinished must not emit a fault value — graceful finish only")
    }
}

// MARK: - FileWriterAudioTests (L2, stub seam)

@Suite("FileWriter — appendAudio paths (L2)")
struct FileWriterAudioTests {
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "FileWriterAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makePCMBuffer() throws -> CMSampleBuffer {
        // Minimal 1-sample PCM CMSampleBuffer for testing the audio append path.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        let desc = try #require(formatDesc)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 44100),
            presentationTimeStamp: CMTime(value: 1000, timescale: 44100),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw TestError.sampleBufferFailed(status)
        }
        return sampleBuffer
    }

    private func makeWriterWithAudio() throws -> FileWriter {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        let url = self.tempDir.appending(path: "test-audio.mp4")
        let hint = try makeHEVCFormatDescription()
        return try FileWriter(
            outputURL: url,
            configuration: .mvpDefault,
            includeAudio: true,
            sourceFormatHint: hint
        )
    }

    @Test("appendAudio on faulted writer is a no-op")
    func appendAudio_faulted_noOp() async throws {
        let writer = try makeWriterWithAudio()
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        // Fault the writer via a video append-false stub.
        let videoStub = StubWriterInput(ready: true, appendReturnValue: false)
        await writer.injectVideoInputForTesting(videoStub)
        let hint = try makeHEVCFormatDescription()
        let pts = CMTime(seconds: 0.5, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var videoBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: hint,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &videoBuffer
        )
        let videoBufferUnwrapped = try #require(videoBuffer)
        let sample = EncodedSample(sampleBuffer: videoBufferUnwrapped, ptsHostTime: pts, isKeyframe: true)
        await writer.appendVideo(sample) // faults the writer

        // Now try audio — the audio stub must remain untouched.
        let audioStub = StubWriterInput(ready: true, appendReturnValue: true)
        await writer.injectAudioInputForTesting(audioStub)
        let pcm = try makePCMBuffer()
        await writer.appendAudio(pcm)

        #expect(audioStub.appendedBuffers.isEmpty, "faulted writer must not append audio")
    }

    @Test("appendAudio with not-ready input → skipped (no DropEvent)")
    func appendAudio_notReady_skipped() async throws {
        let writer = try makeWriterWithAudio()
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let audioStub = StubWriterInput(ready: false)
        await writer.injectAudioInputForTesting(audioStub)

        // Subscribe to drops — audio must never yield a DropEvent.
        let dropCollector = Task { () -> [DropEvent] in
            var events: [DropEvent] = []
            for await event in await writer.drops {
                events.append(event)
            }
            return events
        }

        let pcm = try makePCMBuffer()
        await writer.appendAudio(pcm)

        await writer.finishDropsForTesting()
        let events = await dropCollector.value

        #expect(events.isEmpty, "audio not-ready must not emit a DropEvent")
        #expect(audioStub.appendedBuffers.isEmpty, "not-ready audio input must not have buffer appended")
    }

    @Test("appendAudio with append()==false → faults writer, no DropEvent")
    func appendAudio_appendReturnsFalse_faultsWriter() async throws {
        let writer = try makeWriterWithAudio()
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let audioStub = StubWriterInput(ready: true, appendReturnValue: false)
        await writer.injectAudioInputForTesting(audioStub)

        let dropCollector = Task { () -> [DropEvent] in
            var events: [DropEvent] = []
            for await event in await writer.drops {
                events.append(event)
            }
            return events
        }

        let pcm = try makePCMBuffer()
        await writer.appendAudio(pcm)

        await writer.finishDropsForTesting()
        let events = await dropCollector.value

        #expect(events.isEmpty, "audio hard failure must not emit a DropEvent")
        let faulted = await writer.isFaultedForTesting
        #expect(faulted, "append()==false on audio must mark the writer faulted")
    }
}

// MARK: - TestError

private enum TestError: Error {
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}

// MARK: - FileWriterLiveTests (L5, real VideoEncoder + AVAssetWriter)

@Suite("FileWriter — L5 integration (real encoder + muxer)", .serialized, .timeLimit(.minutes(2)))
struct FileWriterLiveTests {
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "FileWriterLiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    // MARK: - hvc1 passthrough integration test

    @Test(
        "VideoEncoder → FileWriter → AVAsset: video track has HEVC (hvc1/hev1) format",
        .enabled(if: fileWriterL5Enabled())
    )
    func liveEncode_fileContainsHEVCTrack() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let anchor = makeFixedAnchor()
        let encoder = VideoEncoder(
            settings: makeEncoderSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        )
        try await encoder.start()

        // Feed frames and collect the first EncodedSample to obtain the CMFormatDescription.
        let firstSampleTask = Task { () -> EncodedSample? in
            for await sample in await encoder.encodedSamples {
                return sample
            }
            return nil
        }

        // Feed enough frames to trigger at least one encode.
        for slot in 0..<10 {
            let slotOffset = CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps))
            let frame = VideoFrame(
                pixelBuffer: {
                    let buf = makePixelBuffer()
                    fillSolidGrey(buf)
                    return buf
                }(),
                ptsHostTime: CMTimeAdd(anchor.anchorTime, slotOffset),
                isHoldRepeat: false
            )
            await encoder.ingest(frame)
        }

        await encoder.stop()

        let firstSample = try #require(await firstSampleTask.value, "encoder produced no samples")

        // Extract the CMFormatDescription from the first compressed sample.
        let formatHint = try #require(
            CMSampleBufferGetFormatDescription(firstSample.sampleBuffer),
            "no format description on first sample"
        )

        // Verify init-contract branch: sourceFormatHint is required for MP4 (see FileWriter's
        // type-level doc — nil-hint crashes at AVAssetWriter.add(input:)). Here we exercise the
        // with-hint path end-to-end and assert the encoder's subtype round-trips unchanged.
        let outputURL = self.tempDir.appending(path: "test-hvc1.mp4")
        let writer = try FileWriter(
            outputURL: outputURL,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: formatHint
        )

        // t0 = first sample's PTS (raw anchored value — no conversion per PTS landmine note).
        try await writer.start(atSourceTime: firstSample.ptsHostTime)
        await writer.appendVideo(firstSample)

        // Re-collect remaining samples from the stopped encoder stream.
        for await sample in await encoder.encodedSamples {
            await writer.appendVideo(sample)
        }

        await writer.markFinished()
        let result = await writer.finish()

        guard case .completed = result else {
            Issue.record("writer did not complete: \(result)")
            return
        }

        // Inspect the written file: it must contain a video track with an HEVC subtype.
        let asset = AVAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "no video tracks in written file")

        let track = try #require(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        #expect(!formatDescriptions.isEmpty, "video track has no format descriptions")

        let trackFormat = try #require(formatDescriptions.first)
        let mediaSubType = CMFormatDescriptionGetMediaSubType(trackFormat)

        // The encoder's compressed format subtype (hvc1 or hev1) must round-trip through
        // the passthrough muxer unchanged. Both are valid HEVC-in-MP4 tags.
        let encoderSubType = CMFormatDescriptionGetMediaSubType(formatHint)
        let encoderTag = FileWriter.fourCC(encoderSubType)
        let fileTag = FileWriter.fourCC(mediaSubType)
        #expect(
            mediaSubType == encoderSubType,
            "expected subtype \(encoderTag) from encoder, got \(fileTag) in file"
        )
    }

    // MARK: - movieFragmentInterval test

    @Test(
        "movieFragmentInterval is set on the writer before startWriting",
        .enabled(if: fileWriterL5Enabled())
    )
    func movieFragmentInterval_setBeforeStart_liveEncoder() async throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        // Obtain a real format description via a live encoder.
        let anchor = makeFixedAnchor()
        let encoder = VideoEncoder(
            settings: makeEncoderSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        )
        try await encoder.start()

        let firstSampleTask = Task { () -> EncodedSample? in
            for await sample in await encoder.encodedSamples {
                return sample
            }
            return nil
        }
        for slot in 0..<5 {
            let slotOffset = CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps))
            let frame = VideoFrame(
                pixelBuffer: { let buf = makePixelBuffer()
                    fillSolidGrey(buf)
                    return buf
                }(),
                ptsHostTime: CMTimeAdd(anchor.anchorTime, slotOffset),
                isHoldRepeat: false
            )
            await encoder.ingest(frame)
        }
        await encoder.stop()
        let firstSample = try #require(await firstSampleTask.value)
        let hint = try #require(CMSampleBufferGetFormatDescription(firstSample.sampleBuffer))

        let outputURL = self.tempDir.appending(path: "test-fragment.mp4")
        let writer = try FileWriter(
            outputURL: outputURL,
            configuration: .mvpDefault,
            includeAudio: false,
            sourceFormatHint: hint
        )

        // The observable effect of movieFragmentInterval being set correctly is that
        // startWriting() succeeds AND the file is finalised in fragments. We verify the
        // interval is the expected value via the testable accessor.
        let interval = await writer.movieFragmentIntervalForTesting
        let expected = CMTime(
            seconds: RecordingConfiguration.mvpDefault.movieFragmentInterval,
            preferredTimescale: 600
        )
        #expect(CMTimeCompare(interval, expected) == 0)
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable function_body_length
// file_length stays disabled through EOF: it is a whole-file rule, so re-enabling it before the
// last line would re-trigger on the total count. The file intentionally collects L2 + L5 paths.
