import AVFoundation
import CoreMedia
import CoreVideo
@testable import Onset
import Testing

// no_magic_numbers is disabled file-wide: these are Swift Testing structs (no XCTest
// parent class), so the rule's `test_parent_classes` exclusion in .swiftlint.yml does
// not apply; the numeric literals here are expected-value test data, not magic numbers.
// swiftlint:disable no_magic_numbers
// file_length is disabled: this single-concern test file covers all pure helpers from
// CameraSource; it naturally grows alongside the helpers it tests.
// swiftlint:disable file_length

// MARK: - T0 gating tests

@Suite("CameraSource — T0 gating")
struct CameraT0GatingTests {
    private let anchorT0 = CMTime(value: 10, timescale: 1)

    @Test("frame strictly before T0 is dropped")
    func frameBefore_T0_isDropped() {
        let beforeT0 = CMTime(value: 9, timescale: 1)
        #expect(shouldKeepCameraFrame(frameHostTime: beforeT0, sessionStart: self.anchorT0) == false)
    }

    @Test("frame one millisecond before T0 is dropped")
    func frameOneMillisecondBefore_T0_isDropped() {
        let justBefore = CMTime(value: 9999, timescale: 1000)
        #expect(shouldKeepCameraFrame(frameHostTime: justBefore, sessionStart: self.anchorT0) == false)
    }

    @Test("frame exactly at T0 is kept")
    func frameAt_T0_isKept() {
        #expect(shouldKeepCameraFrame(frameHostTime: self.anchorT0, sessionStart: self.anchorT0) == true)
    }

    @Test("frame one millisecond after T0 is kept")
    func frameOneMillisecondAfter_T0_isKept() {
        let justAfter = CMTime(value: 10001, timescale: 1000)
        #expect(shouldKeepCameraFrame(frameHostTime: justAfter, sessionStart: self.anchorT0) == true)
    }

    @Test("frame strictly after T0 is kept")
    func frameAfter_T0_isKept() {
        let after = CMTime(value: 11, timescale: 1)
        #expect(shouldKeepCameraFrame(frameHostTime: after, sessionStart: self.anchorT0) == true)
    }

    @Test("zero T0 keeps frame at zero PTS")
    func zeroT0_keepsPtsAtZero() {
        #expect(shouldKeepCameraFrame(frameHostTime: CMTime.zero, sessionStart: CMTime.zero) == true)
    }

    @Test("zero T0 drops negative PTS")
    func zeroT0_dropsNegativePts() {
        let negativePts = CMTime(value: -1, timescale: 1)
        #expect(shouldKeepCameraFrame(frameHostTime: negativePts, sessionStart: CMTime.zero) == false)
    }
}

// MARK: - Capture drop event tests

@Suite("CameraSource — capture drop event")
struct CaptureDropEventTests {
    private let pts = CMTime(value: 1000, timescale: 1000)

    @Test("captureDropEvent produces DropEvent with .captureDrop reason")
    func captureDropEvent_hasCaptureDropReason() {
        let event = captureDropEvent(pts: self.pts)
        guard case .captureDrop = event.reason else {
            Issue.record("Expected .captureDrop, got \(event.reason)")
            return
        }
        #expect(event.count == 1)
    }

    @Test("captureDropEvent detectedAt matches pts")
    func captureDropEvent_detectedAtMatchesPts() {
        let event = captureDropEvent(pts: self.pts)
        #expect(event.detectedAt == self.pts)
    }

    @Test("captureDropEvent with count > 1")
    func captureDropEvent_withLargerCount() {
        let event = captureDropEvent(pts: self.pts, count: 3)
        #expect(event.count == 3)
        guard case .captureDrop = event.reason else {
            Issue.record("Expected .captureDrop")
            return
        }
    }
}

// MARK: - Video backpressure drop event tests

@Suite("CameraSource — video backpressure drop event")
struct VideoBPDropEventTests {
    private let pts = CMTime(value: 2000, timescale: 1000)

    private func makeMinimalPixelBuffer() -> CVPixelBuffer {
        var buf: CVPixelBuffer!
        CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buf)
        return buf
    }

    private func makeDroppedResult() -> AsyncStream<VideoFrame>.Continuation.YieldResult {
        var cont: AsyncStream<VideoFrame>.Continuation!
        let stream = AsyncStream<VideoFrame>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        let buf = self.makeMinimalPixelBuffer()
        let dummy = VideoFrame(pixelBuffer: buf, ptsHostTime: self.pts, isHoldRepeat: false)
        _ = cont.yield(dummy)
        let result = cont.yield(dummy)
        withExtendedLifetime(stream) {}
        return result
    }

    private func makeEnqueuedResult() -> AsyncStream<VideoFrame>.Continuation.YieldResult {
        var cont: AsyncStream<VideoFrame>.Continuation!
        let stream = AsyncStream<VideoFrame>(bufferingPolicy: .bufferingNewest(4)) { cont = $0 }
        let buf = self.makeMinimalPixelBuffer()
        let dummy = VideoFrame(pixelBuffer: buf, ptsHostTime: self.pts, isHoldRepeat: false)
        let result = cont.yield(dummy)
        withExtendedLifetime(stream) {}
        return result
    }

    private func makeTerminatedResult() -> AsyncStream<VideoFrame>.Continuation.YieldResult {
        var cont: AsyncStream<VideoFrame>.Continuation!
        _ = AsyncStream<VideoFrame>(bufferingPolicy: .bufferingNewest(4)) { cont = $0 }
        cont.finish()
        let buf = self.makeMinimalPixelBuffer()
        let dummy = VideoFrame(pixelBuffer: buf, ptsHostTime: self.pts, isHoldRepeat: false)
        return cont.yield(dummy)
    }

    @Test(".dropped yield result produces DropEvent with .encoderBackpressureDrops")
    func droppedYield_producesDropEvent() throws {
        let result = cameraBackpressureDropEvent(for: makeDroppedResult(), pts: self.pts)
        let drop = try #require(result)
        guard case .encoderBackpressureDrops = drop.reason else {
            Issue.record("Expected .encoderBackpressureDrops, got \(drop.reason)")
            return
        }
        #expect(drop.count == 1)
        #expect(drop.detectedAt == self.pts)
    }

    @Test(".enqueued yield result produces nil")
    func enqueuedYield_producesNil() {
        let result = cameraBackpressureDropEvent(for: makeEnqueuedResult(), pts: self.pts)
        #expect(result == nil)
    }

    @Test(".terminated yield result produces nil")
    func terminatedYield_producesNil() {
        let result = cameraBackpressureDropEvent(for: makeTerminatedResult(), pts: self.pts)
        #expect(result == nil)
    }
}

// MARK: - Audio backpressure drop event tests

@Suite("CameraSource — audio backpressure drop event")
struct AudioBPDropEventTests {
    private let pts = CMTime(value: 3000, timescale: 1000)

    /// Creates a minimal `CMSampleBuffer` backed by a 16-bit mono 44.1 kHz format description.
    private func makeMinimalAudioSampleBuffer() -> CMSampleBuffer {
        var fmt: CMAudioFormatDescription!
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        var sampleBuf: CMSampleBuffer!
        CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuf
        )
        return sampleBuf
    }

    private func makeDroppedAudioResult() -> AsyncStream<AudioSample>.Continuation.YieldResult {
        var cont: AsyncStream<AudioSample>.Continuation!
        let stream = AsyncStream<AudioSample>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        let dummy = AudioSample(sampleBuffer: self.makeMinimalAudioSampleBuffer(), ptsHostTime: self.pts)
        _ = cont.yield(dummy)
        let result = cont.yield(dummy)
        withExtendedLifetime(stream) {}
        return result
    }

    @Test(".dropped audio yield result produces DropEvent with .encoderBackpressureDrops")
    func droppedAudioYield_producesDropEvent() throws {
        let result = audioBackpressureDropEvent(for: makeDroppedAudioResult(), pts: self.pts)
        let drop = try #require(result)
        guard case .encoderBackpressureDrops = drop.reason else {
            Issue.record("Expected .encoderBackpressureDrops, got \(drop.reason)")
            return
        }
        #expect(drop.count == 1)
    }
}

// MARK: - Permission decision tests

@Suite("CameraSource — permission decision")
struct PermissionDecisionTests {
    @Test("both authorized → capture authorized")
    func bothAuthorized_isAuthorized() {
        #expect(isCaptureAuthorized(video: .authorized, audio: .authorized) == true)
    }

    @Test("video denied → not authorized")
    func videoDenied_isNotAuthorized() {
        #expect(isCaptureAuthorized(video: .denied, audio: .authorized) == false)
    }

    @Test("audio denied → not authorized")
    func audioDenied_isNotAuthorized() {
        #expect(isCaptureAuthorized(video: .authorized, audio: .denied) == false)
    }

    @Test("both not determined → not authorized")
    func bothNotDetermined_isNotAuthorized() {
        #expect(isCaptureAuthorized(video: .notDetermined, audio: .notDetermined) == false)
    }

    @Test("video restricted → not authorized")
    func videoRestricted_isNotAuthorized() {
        #expect(isCaptureAuthorized(video: .restricted, audio: .authorized) == false)
    }
}

// MARK: - Host-time conversion tests

@Suite("CameraSource — host-time conversion")
struct HostTimeConversionTests {
    @Test("converting from host clock to host clock is identity")
    func convertFromHostClock_isIdentity() {
        let hostClock = CMClockGetHostTimeClock()
        let pts = CMTime(value: 12345, timescale: 44100)
        let result = toHostTime(pts: pts, from: hostClock)
        // CMSyncConvertTime from host→host returns same value (identity).
        #expect(result.timescale == pts.timescale)
        #expect(result.value == pts.value)
    }
}

// MARK: - L5 live hardware harness

// MARK: - Stop teardown contract tests

/// Guards the nil-session teardown branch in `CameraSource.stop()`.
///
/// Constructs a `CameraSource` from synthetic value-type models (no live device),
/// calls `stop()` WITHOUT ever calling `start()`, and asserts that all streams finish
/// (consumers receive `nil`, not a hang). CI-runnable — no camera or microphone required.
@Suite("CameraSource — stop teardown", .timeLimit(.minutes(1)))
struct CameraSourceStopTeardownTests {
    private static func makeSyntheticSource() -> CameraSource {
        let format = CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 30.0, maxFps: 60.0)
        let device = CameraDevice(uniqueID: "synthetic-camera-id", formats: [format])
        let mic = MicrophoneDevice(uniqueID: "synthetic-mic-id")
        return CameraSource(
            cameraDevice: device,
            format: format,
            micDevice: mic,
            config: .mvpDefault
        )
    }

    @Test("stop() without start() finishes the frames stream")
    func stopWithoutStart_finishesFrames() async {
        let source = Self.makeSyntheticSource()
        await source.stop()
        // AsyncStream whose continuation was finished yields nil on first iteration.
        let first = await source.frames.first { _ in true }
        #expect(first == nil)
    }

    @Test("stop() without start() finishes the audioSamples stream")
    func stopWithoutStart_finishesAudioSamples() async {
        let source = Self.makeSyntheticSource()
        await source.stop()
        let first = await source.audioSamples.first { _ in true }
        #expect(first == nil)
    }

    @Test("stop() without start() finishes the events stream")
    func stopWithoutStart_finishesEvents() async {
        let source = Self.makeSyntheticSource()
        await source.stop()
        let first = await source.events.first { _ in true }
        #expect(first == nil)
    }

    @Test("stop() without start() finishes the drops stream")
    func stopWithoutStart_finishesDrops() async {
        let source = Self.makeSyntheticSource()
        await source.stop()
        let first = await source.drops.first { _ in true }
        #expect(first == nil)
    }
}

// MARK: - L5 opt-in condition

/// Returns `true` when the L5 live-capture test should run.
///
/// Both conditions must hold:
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment (explicit opt-in).
/// 2. TCC authorization is granted for both camera and microphone.
///
/// Used as the `.enabled(if:)` trait on `liveCapture_producesFramesAndSamples` so that
/// a non-opted-in run reports as a genuine SKIP rather than a false PASS.
private func l5CaptureEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1" else {
        return false
    }
    let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    return isCaptureAuthorized(video: videoStatus, audio: audioStatus)
}

// MARK: - L5 live hardware harness

/// Live-hardware capture harness for CameraSource.
///
/// Opt-in: skips (SKIP, not PASS) unless BOTH conditions hold:
/// 1. TCC authorization is granted for camera + microphone.
/// 2. The env flag `ONSET_RUN_L5_CAPTURE=1` is set explicitly.
///
/// This prevents every routine `xcodebuild test` invocation from grabbing the camera
/// unattended (opening the session on an authorized dev machine can hang the test host).
/// To run deliberately: `ONSET_RUN_L5_CAPTURE=1 xcodebuild test …`
@Suite("CameraSource — L5 live hardware", .serialized, .timeLimit(.minutes(1)))
struct CameraSourceLiveTests {
    @Test(
        "live capture produces host-time-stamped video frames and audio samples",
        .enabled(if: l5CaptureEnabled())
    )
    func liveCapture_producesFramesAndSamples() async throws {
        let setup = try makeLiveCaptureSource()

        try await setup.source.start(anchoredTo: setup.anchor)

        let result: LiveCaptureResult
        do {
            result = try await collectFrames(from: setup.source, anchor: setup.anchor, targetCount: 5)
        } catch {
            await setup.source.stop()
            Issue.record("L5 capture did not deliver 5 frames within 15s: \(error)")
            return
        }
        await setup.source.stop()

        assertVideoFrames(result.frames, anchor: setup.anchor, format: setup.format)
        assertAudioSamples(result.samples, anchor: setup.anchor)
    }
}

// MARK: - L5 setup helper

private struct LiveCaptureSetup {
    let source: CameraSource
    let format: CameraFormat
    let anchor: HostTimeAnchor
}

/// Builds and configures a `CameraSource` from the first available built-in camera and
/// default microphone. Returns the configured source, the selected format, and a fresh anchor.
///
/// Extracted to keep `liveCapture_producesFramesAndSamples` within `function_body_length`.
private func makeLiveCaptureSource() throws -> LiveCaptureSetup {
    guard let avDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera,
        for: .video,
        position: .unspecified
    ) else {
        throw L5SetupError.noCamera
    }
    guard let avMic = AVCaptureDevice.default(for: .audio) else {
        throw L5SetupError.noMicrophone
    }

    let formats: [CameraFormat] = avDevice.formats.compactMap { fmt in
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let maxFps = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        let minFps = fmt.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
        return CameraFormat(
            pixelWidth: dims.width,
            pixelHeight: dims.height,
            minFps: minFps,
            maxFps: maxFps
        )
    }

    let config = RecordingConfiguration.mvpDefault
    let selectedFormat = try CameraFormatSelector.pickBestFormat(
        from: formats,
        minFps: Double(config.minCameraFps)
    )

    let cameraDevice = CameraDevice(uniqueID: avDevice.uniqueID, formats: formats)
    let micDevice = MicrophoneDevice(uniqueID: avMic.uniqueID)
    let source = CameraSource(
        cameraDevice: cameraDevice,
        format: selectedFormat,
        micDevice: micDevice,
        config: config
    )
    return LiveCaptureSetup(source: source, format: selectedFormat, anchor: HostTimeAnchor.now())
}

// MARK: - L5 error types

private enum L5SetupError: Error {
    case noCamera
    case noMicrophone
}

private struct L5TimeoutError: Error {}

// MARK: - L5 helpers

private struct LiveCaptureResult {
    let frames: [VideoFrame]
    let samples: [AudioSample]
}

nonisolated private func collectFrames(
    from source: CameraSource,
    anchor: HostTimeAnchor,
    targetCount: Int
) async throws
-> LiveCaptureResult {
    // Extract nonisolated streams before spawning child tasks — avoids actor hop in closures.
    // `nonisolated let` streams on the actor are safe to pass across concurrency boundaries.
    let videoStream = source.frames
    let audioStream = source.audioSamples

    // Race the collectors against a 15s deadline. If the camera is busy or contended the
    // timeout task throws L5TimeoutError, cancelling the collector tasks. AsyncStream
    // iteration returns nil on cancellation, so the loops exit without hanging.
    return try await withThrowingTaskGroup(of: LiveCaptureResult.self) { group in
        group.addTask {
            async let videoFrames: [VideoFrame] = collectVideoFrames(from: videoStream, count: targetCount)
            async let audioSamples: [AudioSample] = collectAudioSamples(from: audioStream, count: targetCount)
            let frames = await videoFrames
            let samples = await audioSamples
            return LiveCaptureResult(frames: frames, samples: samples)
        }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            throw L5TimeoutError()
        }
        guard let result = try await group.next() else { throw L5TimeoutError() }
        group.cancelAll()
        return result
    }
}

nonisolated private func collectVideoFrames(
    from stream: AsyncStream<VideoFrame>,
    count: Int
) async
-> [VideoFrame] {
    var collected: [VideoFrame] = []
    for await frame in stream {
        collected.append(frame)
        if collected.count >= count { break }
    }
    return collected
}

nonisolated private func collectAudioSamples(
    from stream: AsyncStream<AudioSample>,
    count: Int
) async
-> [AudioSample] {
    var collected: [AudioSample] = []
    for await sample in stream {
        collected.append(sample)
        if collected.count >= count { break }
    }
    return collected
}

nonisolated private func assertVideoFrames(
    _ frames: [VideoFrame],
    anchor: HostTimeAnchor,
    format: CameraFormat
) {
    #expect(!frames.isEmpty, "Expected at least one video frame")
    for frame in frames {
        #expect(frame.ptsHostTime.value > 0)
        #expect(CMTimeCompare(frame.ptsHostTime, anchor.anchorTime) >= 0)
        #expect(frame.isHoldRepeat == false)
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        #expect(width == Int(format.pixelWidth))
        #expect(height == Int(format.pixelHeight))
        let pixFmt = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        #expect(pixFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
    for index in 1..<frames.count {
        #expect(CMTimeCompare(frames[index].ptsHostTime, frames[index - 1].ptsHostTime) >= 0)
    }
}

nonisolated private func assertAudioSamples(_ samples: [AudioSample], anchor: HostTimeAnchor) {
    #expect(!samples.isEmpty, "Expected at least one audio sample")
    for sample in samples {
        #expect(sample.ptsHostTime.value > 0)
        #expect(CMTimeCompare(sample.ptsHostTime, anchor.anchorTime) >= 0)
    }
}

// swiftlint:enable no_magic_numbers
