import AVFoundation
import CoreMedia
import CoreVideo
@testable import Onset
import os
import Testing

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

// MARK: - Disconnect filter tests (AC-12 regression)

/// Locks the B1 fix: unplugging a non-camera device (e.g. microphone) must NOT trigger
/// the disconnect handler. Tests the `shouldHandleDisconnect` pure helper extracted from
/// `VideoOutputShim.deviceDidDisconnect(_:)`.
@Suite("CameraSource — disconnect filter")
struct DisconnectFilterTests {
    private let cameraID = "camera-unique-id"

    @Test("matching device ID triggers disconnect")
    func matchingID_triggersDisconnect() {
        #expect(shouldHandleDisconnect(notificationDeviceID: self.cameraID, cameraID: self.cameraID) == true)
    }

    @Test("non-matching device ID does not trigger disconnect")
    func nonMatchingID_doesNotTriggerDisconnect() {
        #expect(shouldHandleDisconnect(notificationDeviceID: "other-device-id", cameraID: self.cameraID) == false)
    }

    @Test("nil device ID (non-AVCaptureDevice notification object) does not trigger disconnect")
    func nilID_doesNotTriggerDisconnect() {
        #expect(shouldHandleDisconnect(notificationDeviceID: nil, cameraID: self.cameraID) == false)
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

// MARK: - Stop teardown (nil mic) tests (AC-11 regression)

/// Guards the nil-mic teardown path in `CameraSource.stop()`.
///
/// Constructs a `CameraSource` with `micDevice: nil` (screen-only-compatible path) and
/// asserts that `stop()` finishes all streams cleanly without ever calling `start()`.
/// The load-bearing assertion is `audioSamples` — confirms the audio continuation is
/// finished even when no microphone device was provided at init time.
/// CI-runnable — no camera or microphone hardware required.
@Suite("CameraSource — stop teardown (nil mic)", .timeLimit(.minutes(1)))
struct CameraSourceNilMicStopTeardownTests {
    private static func makeNilMicSource() -> CameraSource {
        let format = CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 30.0, maxFps: 60.0)
        let device = CameraDevice(uniqueID: "synthetic-camera-id", formats: [format])
        return CameraSource(
            cameraDevice: device,
            format: format,
            micDevice: nil,
            config: .mvpDefault
        )
    }

    @Test("nil-mic stop() without start() finishes the audioSamples stream")
    func nilMic_stopWithoutStart_finishesAudioSamples() async {
        let source = Self.makeNilMicSource()
        await source.stop()
        // audioSamples must finish (yield nil) regardless of whether a mic was provided.
        let first = await source.audioSamples.first { _ in true }
        #expect(first == nil)
    }

    @Test("nil-mic stop() without start() finishes the frames stream")
    func nilMic_stopWithoutStart_finishesFrames() async {
        let source = Self.makeNilMicSource()
        await source.stop()
        let first = await source.frames.first { _ in true }
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

/// Returns `true` when the L5 Brio fps-lock tests should run.
///
/// Three conditions must all hold:
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment (explicit opt-in).
/// 2. TCC authorization is granted for both camera and microphone.
/// 3. A camera whose `localizedName` contains "Brio" (case-insensitive) is connected.
///
/// Condition 3 yields a genuine SKIP on machines without the Brio — not a failure.
private func l5BrioEnabled() -> Bool {
    guard l5CaptureEnabled() else { return false }
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    return discoverySession.devices.contains { $0.localizedName.localizedCaseInsensitiveContains("Brio") }
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

    @Test(
        "preview role starts successfully and produces no frames within 1s",
        .enabled(if: l5CaptureEnabled())
    )
    func previewRole_producesNoFrames() async throws {
        let setup = try makeLiveCaptureSource(role: .preview)
        try await setup.source.start(anchoredTo: setup.anchor)

        // Positive: session must have started — a nil handle means start() silently failed.
        #expect(await setup.source.sessionHandle() != nil)
        // Role-gating: preview must not launch the telemetry flush task.
        #expect(await setup.source.captureTelemetryTask == nil)

        // Race a frame-wait task against a 1s timeout; the timeout winning is the expected path.
        let gotFrame = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in setup.source.frames {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        await setup.source.stop()
        #expect(gotFrame == false, "Preview CameraSource must not yield frames (issue #119)")
    }
}

// MARK: - L5 Brio fps-lock + real-frame dimension tests (issue #113)

/// Live-hardware tests for the Brio camera mode override (issue #113).
///
/// Opt-in: skips unless `ONSET_RUN_L5_CAPTURE=1` AND a Brio camera is connected.
/// Serialized so the two mode tests do not contend over the same hardware device.
@Suite("CameraSource — L5 Brio (#113)", .serialized, .timeLimit(.minutes(2)))
struct CameraSourceBrioTests {
    // MARK: - L5 Brio fps-lock tests (issue #113)

    /// Proves that selecting a 4K 30 fps `CameraMode` override activates a 3840×2160
    /// format on the live Brio device and pins the frame duration to 30 fps.
    ///
    /// The test first delivers one real frame from the camera's `AsyncStream` and reads its
    /// `CVPixelBuffer` dimensions — the authoritative signal for issue #113. `device.activeFormat`
    /// dims are logged side-by-side with the real-frame dims so a stale-property divergence is
    /// immediately visible in the run transcript. The existing `activeFormat` and fps-lock
    /// assertions are kept as a secondary signal.
    @Test(
        "Brio 4K30 mode override activates 3840×2160 format pinned to 30 fps",
        .enabled(if: l5BrioEnabled())
    )
    func brioCameraMode_4K30_activatesFormatAndFpsLock() async throws {
        let setup = try makeBrioCameraSource(mode: CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30))
        defer { Task { await setup.source.stop() } }

        // Pre-flight: resolveFormat must have matched the override, not fallen back to auto.
        #expect(
            setup.format.pixelWidth == 3840 && setup.format.pixelHeight == 2160,
            "resolveFormat fell back to auto — Brio does not advertise a 3840×2160 format"
        )
        #expect(
            setup.targetFps == 30,
            "resolveFormat returned fps \(setup.targetFps), expected 30"
        )

        try await setup.source.start(anchoredTo: setup.anchor)

        // ── Real-frame dimension check (authoritative for issue #113) ─────────────────────
        // Pull the first delivered CVPixelBuffer from the live stream to read its ACTUAL
        // dimensions. This bypasses device.activeFormat, which macOS may revert after the
        // session starts while the delivered frames still carry the originally negotiated size.
        let firstFrame = try await collectFirstVideoFrame(from: setup.source.frames)
        let frameWidth = CVPixelBufferGetWidth(firstFrame.pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(firstFrame.pixelBuffer)

        // Re-acquire the device by uniqueID — same per-process AVFoundation instance
        // that CameraSource configured inside addCameraInput.
        guard let avDevice = AVCaptureDevice(uniqueID: setup.cameraUniqueID) else {
            Issue.record("AVCaptureDevice lost after start() — cannot inspect activeFormat")
            return
        }

        let activeDims = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)

        // TEMP-LOG DIAGNOSTIC #113: real-frame dims vs device.activeFormat dims side-by-side.
        let log = Logger(subsystem: "dev.androidbroadcast.Onset", category: "DIAG.113")
        log.notice(
            "DIAGNOSTIC #113 [4K30] real=\(frameWidth, privacy: .public)x\(frameHeight, privacy: .public)"
        )
        log.notice(
            "DIAGNOSTIC #113 [4K30] active=\(activeDims.width, privacy: .public)x\(activeDims.height, privacy: .public)"
        )

        // Authoritative assertion: the delivered pixel buffer must be 3840×2160.
        #expect(frameWidth == 3840, "real frame width should be 3840, got \(frameWidth)")
        #expect(frameHeight == 2160, "real frame height should be 2160, got \(frameHeight)")

        // Secondary assertion: device.activeFormat (may be stale on macOS 26.x).
        #expect(activeDims.width == 3840, "activeFormat width should be 3840, got \(activeDims.width)")
        #expect(activeDims.height == 2160, "activeFormat height should be 2160, got \(activeDims.height)")

        assertFpsLock(on: avDevice, targetFps: 30)
    }

    /// Proves that selecting a 1080p 60 fps `CameraMode` override activates a 1920×1080
    /// format on the live Brio device and pins the frame duration to 60 fps.
    ///
    /// The test first delivers one real frame from the camera's `AsyncStream` and reads its
    /// `CVPixelBuffer` dimensions — the authoritative signal for issue #113. `device.activeFormat`
    /// dims are logged side-by-side with the real-frame dims so a stale-property divergence is
    /// immediately visible in the run transcript. The existing `activeFormat` and fps-lock
    /// assertions are kept as a secondary signal.
    @Test(
        "Brio 1080p60 mode override activates 1920×1080 format pinned to 60 fps",
        .enabled(if: l5BrioEnabled())
    )
    func brioCameraMode_1080p60_activatesFormatAndFpsLock() async throws {
        let setup = try makeBrioCameraSource(mode: CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60))
        defer { Task { await setup.source.stop() } }

        // Pre-flight: resolveFormat must have matched the override, not fallen back to auto.
        #expect(
            setup.format.pixelWidth == 1920 && setup.format.pixelHeight == 1080,
            "resolveFormat fell back to auto — Brio does not advertise a 1920×1080 format"
        )
        #expect(
            setup.targetFps == 60,
            "resolveFormat returned fps \(setup.targetFps), expected 60"
        )

        try await setup.source.start(anchoredTo: setup.anchor)

        // ── Real-frame dimension check (authoritative for issue #113) ─────────────────────
        // Pull the first delivered CVPixelBuffer from the live stream to read its ACTUAL
        // dimensions. This bypasses device.activeFormat, which macOS may revert after the
        // session starts while the delivered frames still carry the originally negotiated size.
        let firstFrame = try await collectFirstVideoFrame(from: setup.source.frames)
        let frameWidth = CVPixelBufferGetWidth(firstFrame.pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(firstFrame.pixelBuffer)

        guard let avDevice = AVCaptureDevice(uniqueID: setup.cameraUniqueID) else {
            Issue.record("AVCaptureDevice lost after start() — cannot inspect activeFormat")
            return
        }

        let activeDims = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)

        // TEMP-LOG DIAGNOSTIC #113: real-frame dims vs device.activeFormat dims side-by-side.
        let log = Logger(subsystem: "dev.androidbroadcast.Onset", category: "DIAG.113")
        log.notice(
            "DIAGNOSTIC #113 [1080p] real=\(frameWidth, privacy: .public)x\(frameHeight, privacy: .public)"
        )
        log.notice(
            "DIAGNOSTIC #113 [1080p] fmt=\(activeDims.width, privacy: .public)x\(activeDims.height, privacy: .public)"
        )

        // Authoritative assertion: the delivered pixel buffer must be 1920×1080.
        #expect(frameWidth == 1920, "real frame width should be 1920, got \(frameWidth)")
        #expect(frameHeight == 1080, "real frame height should be 1080, got \(frameHeight)")

        // Secondary assertion: device.activeFormat (may be stale on macOS 26.x).
        #expect(activeDims.width == 1920, "activeFormat width should be 1920, got \(activeDims.width)")
        #expect(activeDims.height == 1080, "activeFormat height should be 1080, got \(activeDims.height)")

        assertFpsLock(on: avDevice, targetFps: 60)
    }

    // MARK: - DIAGNOSTIC #113 — dump real Brio format list (TEMPORARY)

    // swiftlint:disable function_body_length

    /// TEMPORARY diagnostic — dumps the real MX Brio format list via os.Logger so
    /// `resolveFormat` bugs in issue #113 can be fixed against ground truth.
    ///
    /// Three sub-dumps (each line prefixed "DIAG #113"):
    ///   1. Raw AVFoundation formats: dims, FourCC, fps ranges, isVideoBinned.
    ///   2. CameraFormat snapshots as the production mapper sees them.
    ///   3. availableModes + resolveFormat results for 4K30 and 1080p60 overrides.
    ///
    /// The test asserts nothing critical — `#expect(device != nil)` is the only gate
    /// so it counts as run. Remove this test after issue #113 is fixed.
    /// DIAGNOSTIC #113
    @Test(
        "DIAG — dump Brio AVFoundation format list (issue #113, TEMPORARY)",
        .enabled(if: l5BrioEnabled())
    )
    func DIAG_dumpBrioFormats() throws {
        // TEMP-LOG: subsystem matches production; category makes log filtering easy.
        let log = Logger(subsystem: "dev.androidbroadcast.Onset", category: "DIAG.113")

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceDiscovery.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let device = discoverySession.devices
            .first { $0.localizedName.localizedCaseInsensitiveContains("Brio") }

        // The only critical assertion — gate passes when the device is present.
        #expect(device != nil, "Brio not found — l5BrioEnabled() should have skipped this test")
        guard let brioAV = device else { return }

        // ── Sub-dump 1: raw AVFoundation formats ──────────────────────────────
        log.notice("DIAG #113 — raw AVFoundation formats count=\(brioAV.formats.count, privacy: .public)")
        for (index, fmt) in brioAV.formats.enumerated() {
            let desc = fmt.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)

            // FourCC as a 4-char string (big-endian bytes).
            // TEMP-LOG: bit-shift instead of withUnsafeBytes — no unsafe/force-unwrap.
            let tag = CMFormatDescriptionGetMediaSubType(desc)
            let fourCC = String(
                [
                    Character(UnicodeScalar(UInt8((tag >> 24) & 0xFF))),
                    Character(UnicodeScalar(UInt8((tag >> 16) & 0xFF))),
                    Character(UnicodeScalar(UInt8((tag >> 8) & 0xFF))),
                    Character(UnicodeScalar(UInt8(tag & 0xFF))),
                ]
            )

            for range in fmt.videoSupportedFrameRateRanges {
                let minFps = range.minFrameRate
                let maxFps = range.maxFrameRate
                let minDur = range.minFrameDuration
                let maxDur = range.maxFrameDuration
                // TEMP-LOG
                log.notice(
                    """
                    DIAG #113 [raw \(index, privacy: .public)] \
                    \(dims.width, privacy: .public)x\(dims.height, privacy: .public) \
                    \(fourCC, privacy: .public) \
                    fps=\(minFps, privacy: .public)-\(maxFps, privacy: .public) \
                    minDur=\(minDur.value, privacy: .public)/\(minDur.timescale, privacy: .public) \
                    maxDur=\(maxDur.value, privacy: .public)/\(maxDur.timescale, privacy: .public)
                    """
                )
            }
        }

        // ── Sub-dump 2: CameraFormat snapshots via production mapper ──────────
        // TEMP-LOG: calls the exact same DeviceDiscovery.makeCameraFormat used in production;
        // divergence between this output and sub-dump 1 isolates the mapping bug.
        let cameraFormats: [CameraFormat] = brioAV.formats.map { DeviceDiscovery.makeCameraFormat(from: $0) }
        log.notice("DIAG #113 — CameraFormat snapshots count=\(cameraFormats.count, privacy: .public)")
        for (index, cameraFmt) in cameraFormats.enumerated() {
            // TEMP-LOG
            log.notice(
                """
                DIAG #113 [mapped \(index, privacy: .public)] \
                \(cameraFmt.pixelWidth, privacy: .public)x\(cameraFmt.pixelHeight, privacy: .public) \
                fps=\(cameraFmt.minFps, privacy: .public)-\(cameraFmt.maxFps, privacy: .public)
                """
            )
        }

        // ── Sub-dump 3: availableModes + resolveFormat for 4K30 and 1080p60 ──
        let config = RecordingConfiguration.mvpDefault
        let modes = CameraFormatSelector.availableModes(from: cameraFormats, config: config)
        log.notice("DIAG #113 — availableModes count=\(modes.count, privacy: .public)")
        for mode in modes {
            // TEMP-LOG
            log.notice(
                """
                DIAG #113 [mode] \
                \(mode.pixelWidth, privacy: .public)x\(mode.pixelHeight, privacy: .public) \
                fps=\(mode.fps, privacy: .public)
                """
            )
        }

        // resolveFormat for 4K30
        do {
            let result = try CameraFormatSelector.resolveFormat(
                from: cameraFormats,
                override: CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30),
                config: config
            )
            // TEMP-LOG
            log.notice(
                """
                DIAG #113 [resolve 4K30] \
                format=\(result.format.pixelWidth, privacy: .public)x\(result.format.pixelHeight, privacy: .public) \
                fps=\(result.fps, privacy: .public)
                """
            )
        } catch {
            // TEMP-LOG
            log.notice("DIAG #113 [resolve 4K30] threw: \(String(describing: error), privacy: .public)")
        }

        // resolveFormat for 1080p60
        do {
            let result = try CameraFormatSelector.resolveFormat(
                from: cameraFormats,
                override: CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60),
                config: config
            )
            // TEMP-LOG
            log.notice(
                """
                DIAG #113 [resolve 1080p60] \
                format=\(result.format.pixelWidth, privacy: .public)x\(result.format.pixelHeight, privacy: .public) \
                fps=\(result.fps, privacy: .public)
                """
            )
        } catch {
            // TEMP-LOG
            log.notice("DIAG #113 [resolve 1080p60] threw: \(String(describing: error), privacy: .public)")
        }
    }

    // swiftlint:enable function_body_length
    // END DIAGNOSTIC #113
}

// MARK: - L5 setup helper

private struct LiveCaptureSetup {
    let source: CameraSource
    let format: CameraFormat
    let anchor: HostTimeAnchor
}

// swiftlint:disable function_body_length
/// Builds and configures a `CameraSource` from the first available built-in camera.
/// For `.record` role also acquires the default microphone; for `.preview` passes `nil`
/// (preview never attaches a data output, so mic hardware is irrelevant).
/// Returns the configured source, the selected format, and a fresh anchor.
///
/// - Parameter role: Which lifecycle the source serves (default `.record`).
///   Pass `.preview` to build a source that suppresses data outputs and telemetry.
///
/// Extracted to keep `liveCapture_producesFramesAndSamples` within `function_body_length`.
private func makeLiveCaptureSource(role: CaptureRole = .record) throws -> LiveCaptureSetup {
    guard let avDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera,
        for: .video,
        position: .unspecified
    ) else {
        throw L5SetupError.noCamera
    }

    let micDevice: MicrophoneDevice?
    switch role {
    case .record:
        guard let avMic = AVCaptureDevice.default(for: .audio) else {
            throw L5SetupError.noMicrophone
        }
        micDevice = MicrophoneDevice(uniqueID: avMic.uniqueID)

    case .preview:
        micDevice = nil
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
    let source = CameraSource(
        cameraDevice: cameraDevice,
        format: selectedFormat,
        micDevice: micDevice,
        config: config,
        role: role
    )
    return LiveCaptureSetup(source: source, format: selectedFormat, anchor: HostTimeAnchor.now())
}

// swiftlint:enable function_body_length

// MARK: - L5 Brio setup helper (issue #113)

/// The result of configuring a `CameraSource` with a `CameraMode` override on the Brio.
///
/// Carries the source and the exact `(format, targetFps)` that `resolveFormat` returned
/// so test bodies can assert the override was honoured before `start()` is called.
private struct BrioCaptureSetup {
    /// The configured source, ready for `start(anchoredTo:)`.
    let source: CameraSource
    /// The `CameraFormat` snapshot chosen by `resolveFormat`.
    let format: CameraFormat
    /// The fps returned by `resolveFormat` — threaded into `CameraSource.init(targetFps:)`.
    let targetFps: Int
    /// The `uniqueID` of the Brio `AVCaptureDevice`, for post-`start()` inspection.
    let cameraUniqueID: String
    /// The session anchor used when starting the source.
    let anchor: HostTimeAnchor
}

// swiftlint:disable function_body_length
/// Builds a `CameraSource` for the Brio camera configured with the given `CameraMode` override.
///
/// - Parameter mode: The mode to pass as `override` to `CameraFormatSelector.resolveFormat`.
/// - Throws: `L5SetupError.noCamera` when no Brio is found (should not happen when
///   `l5BrioEnabled()` is true), `L5SetupError.noMicrophone` when no mic is available,
///   or `RecordingError.noSuitableCameraFormat` when the Brio cannot satisfy the mode.
private func makeBrioCameraSource(mode: CameraMode) throws -> BrioCaptureSetup {
    // Locate the Brio by name. l5BrioEnabled() already confirmed one exists,
    // but we re-query here because test setup runs after the trait evaluation.
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    guard let brioAVDevice = discoverySession.devices
        .first(where: { $0.localizedName.localizedCaseInsensitiveContains("Brio") })
    else {
        throw L5SetupError.noCamera
    }

    // Build the format snapshot list the same way DeviceDiscovery does in production.
    let formats: [CameraFormat] = brioAVDevice.formats.compactMap { fmt in
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
    // resolveFormat honours the mode override and returns the matched (format, fps).
    // The fps value is what CameraSource must receive as targetFps — this is the
    // production wiring path (mirrors MainViewModel.resolveCameraFormat → startRecording).
    let (selectedFormat, resolvedFps) = try CameraFormatSelector.resolveFormat(
        from: formats,
        override: mode,
        config: config
    )

    guard let avMic = AVCaptureDevice.default(for: .audio) else {
        throw L5SetupError.noMicrophone
    }

    let cameraDevice = CameraDevice(uniqueID: brioAVDevice.uniqueID, formats: formats)
    let source = CameraSource(
        cameraDevice: cameraDevice,
        format: selectedFormat,
        micDevice: MicrophoneDevice(uniqueID: avMic.uniqueID),
        config: config,
        targetFps: resolvedFps,
        role: .record
    )
    return BrioCaptureSetup(
        source: source,
        format: selectedFormat,
        targetFps: resolvedFps,
        cameraUniqueID: brioAVDevice.uniqueID,
        anchor: HostTimeAnchor.now()
    )
}

// swiftlint:enable function_body_length

/// Asserts that the device's frame duration is pinned to `targetFps`.
///
/// Production sets `activeVideoMinFrameDuration == activeVideoMaxFrameDuration`
/// (both equal `bestRange.minFrameDuration`). Min == max is the CFR lock proof for issue #113.
/// Tolerates up to 1 fps of rounding error between the target and the rational stored
/// in the AVFrameRateRange (e.g. 29.97 nominal rounds to 30 in the `CameraMode` integer).
nonisolated private func assertFpsLock(on device: AVCaptureDevice, targetFps: Int) {
    let minDuration = device.activeVideoMinFrameDuration
    let maxDuration = device.activeVideoMaxFrameDuration

    // Min == max is the definition of a CFR lock (no range = single rate).
    let minV = minDuration.value
    let minTs = minDuration.timescale
    let maxV = maxDuration.value
    let maxTs = maxDuration.timescale
    if CMTimeCompare(minDuration, maxDuration) != 0 {
        Issue.record(
            "activeVideoMin/MaxFrameDuration must be equal for CFR fps lock — min=\(minV)/\(minTs) max=\(maxV)/\(maxTs)"
        )
    }

    // The actual fps derived from the pinned duration must be within 1 fps of the target.
    let durationSec = CMTimeGetSeconds(minDuration)
    guard durationSec > 0 else {
        Issue.record("activeVideoMinFrameDuration is zero — format not activated")
        return
    }
    let actualFps = 1.0 / durationSec
    if abs(actualFps - Double(targetFps)) > 1.0 {
        Issue.record("fps lock: expected ~\(targetFps) fps, got \(actualFps) fps (duration \(minV)/\(minTs))")
    }
}

// MARK: - L5 error types

private enum L5SetupError: Error {
    case noCamera
    case noMicrophone
}

private struct L5TimeoutError: Error {}

// MARK: - L5 helpers

/// Waits for the first video frame from `stream`, bounded by a 5-second deadline.
///
/// Races a single-frame collector against a timeout task. Returns the first `VideoFrame`
/// delivered by the live camera. Throws `L5TimeoutError` when no frame arrives in time.
/// Used by the Brio fps-lock tests to read the ACTUAL delivered `CVPixelBuffer` dimensions
/// (issue #113) without pulling audio or touching the recording pipeline.
nonisolated private func collectFirstVideoFrame(from stream: AsyncStream<VideoFrame>) async throws -> VideoFrame {
    try await withThrowingTaskGroup(of: VideoFrame?.self) { group in
        group.addTask {
            for await frame in stream {
                return frame
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5)) // swiftlint:disable:this no_magic_numbers
            throw L5TimeoutError()
        }
        guard let result = try await group.next(), let frame = result else {
            group.cancelAll()
            throw L5TimeoutError()
        }
        group.cancelAll()
        return frame
    }
}

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
            try await Task.sleep(for: .seconds(15)) // swiftlint:disable:this no_magic_numbers
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

// MARK: - audioOutputSettings builder tests

// MARK: - Delivery gap helper tests

/// Guards `cameraDeliveryGapMs`, the pure helper that backs the inter-frame gap telemetry.
///
/// Three properties are verified:
/// 1. First delivery (nil previous) records no gap.
/// 2. Second delivery records exactly (pts2 - pts1) * 1000 ms.
/// 3. A negative delta (PTS discontinuity) records 0 ms — clamp from fix 3.
@Suite("CameraSource — delivery gap helper")
struct CameraDeliveryGapTests {
    @Test("first delivery (nil previous) produces nil gap")
    func firstDelivery_producesNilGap() {
        let gap = cameraDeliveryGapMs(previousDeliverySec: nil, currentDeliverySec: 1.0)
        #expect(gap == nil)
    }

    @Test("second delivery records exact gap in milliseconds")
    func secondDelivery_recordsExactGapMs() {
        // 1/30 s ≈ 33.333 ms for a 30 fps stream.
        let pts1 = 1.0
        let pts2 = pts1 + 1.0 / 30.0
        let gap = cameraDeliveryGapMs(previousDeliverySec: pts1, currentDeliverySec: pts2)
        let expected = (pts2 - pts1) * 1000
        #expect(gap == expected)
    }

    @Test("negative PTS delta (discontinuity) is clamped to zero")
    func negativeDelta_clampedToZero() {
        // Simulates a device reconnect where the new PTS is earlier than the previous one.
        let gap = cameraDeliveryGapMs(previousDeliverySec: 2.0, currentDeliverySec: 1.5)
        #expect(gap == 0)
    }

    @Test("zero delta records zero gap")
    func zeroDelta_recordsZeroGap() {
        let gap = cameraDeliveryGapMs(previousDeliverySec: 1.0, currentDeliverySec: 1.0)
        #expect(gap == 0)
    }
}

@Suite("CameraSource — audioOutputSettings builder")
struct CameraSourceAudioSettingsTests {
    private let sampleRate: Double = 48000
    private let channelCount = 1

    @Test("format ID is kAudioFormatLinearPCM")
    func formatID_isLPCM() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let formatID = settings[AVFormatIDKey] as? AudioFormatID
        #expect(formatID == kAudioFormatLinearPCM)
    }

    @Test("sample rate matches config")
    func sampleRate_matchesConfig() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let rate = settings[AVSampleRateKey] as? Double
        #expect(rate == self.sampleRate)
    }

    @Test("channel count matches config")
    func channelCount_matchesConfig() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let count = settings[AVNumberOfChannelsKey] as? Int
        #expect(count == self.channelCount)
    }

    @Test("bit depth is 32")
    func bitDepth_is32() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let depth = settings[AVLinearPCMBitDepthKey] as? Int
        #expect(depth == 32)
    }

    @Test("float flag is true (float32, not int)")
    func floatFlag_isTrue() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let isFloat = settings[AVLinearPCMIsFloatKey] as? Bool
        #expect(isFloat == true)
    }

    @Test("non-interleaved flag is false (interleaved)")
    func nonInterleaved_isFalse() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let nonInterleaved = settings[AVLinearPCMIsNonInterleaved] as? Bool
        #expect(nonInterleaved == false)
    }

    @Test("big-endian flag is false (little-endian)")
    func bigEndian_isFalse() {
        let settings = CameraSource.audioOutputSettings(
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        let bigEndian = settings[AVLinearPCMIsBigEndianKey] as? Bool
        #expect(bigEndian == false)
    }

    @Test("stereo channel count propagates correctly")
    func channelCount_stereoRoundtrips() {
        let settings = CameraSource.audioOutputSettings(sampleRate: self.sampleRate, channelCount: 2)
        let count = settings[AVNumberOfChannelsKey] as? Int
        #expect(count == 2)
    }
}
