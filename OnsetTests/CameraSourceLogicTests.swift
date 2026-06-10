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

    @Test(".dropped yield result produces DropEvent with .captureBackpressureDrops")
    func droppedYield_producesDropEvent() throws {
        let result = cameraBackpressureDropEvent(for: makeDroppedResult(), pts: self.pts)
        let drop = try #require(result)
        guard case .captureBackpressureDrops = drop.reason else {
            Issue.record("Expected .captureBackpressureDrops, got \(drop.reason)")
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

    @Test(".dropped audio yield result produces DropEvent with .captureBackpressureDrops")
    func droppedAudioYield_producesDropEvent() throws {
        let result = audioBackpressureDropEvent(for: makeDroppedAudioResult(), pts: self.pts)
        let drop = try #require(result)
        guard case .captureBackpressureDrops = drop.reason else {
            Issue.record("Expected .captureBackpressureDrops, got \(drop.reason)")
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

// MARK: - Session-fault filter tests (#119 regression)

/// Locks the #119 fix: session-level notifications (runtime error, interruption) from
/// the separate preview `CameraSource` session must NOT trigger the fault handler.
/// Tests the `shouldHandleSessionFault` pure helper extracted from
/// `VideoOutputShim.sessionRuntimeError(_:)` and `VideoOutputShim.sessionWasInterrupted(_:)`.
@Suite("CameraSource — session-fault filter")
struct SessionFaultFilterTests {
    private let session = NSObject()

    @Test("same session object triggers fault handler")
    func sameSessionObject_triggersFaultHandler() {
        let sessionID = ObjectIdentifier(self.session)
        #expect(shouldHandleSessionFault(notificationObject: self.session, sessionID: sessionID) == true)
    }

    @Test("different session object does not trigger fault handler")
    func differentSessionObject_doesNotTriggerFaultHandler() {
        let sessionID = ObjectIdentifier(self.session)
        let otherSession = NSObject()
        #expect(shouldHandleSessionFault(notificationObject: otherSession, sessionID: sessionID) == false)
    }

    @Test("nil notification object does not trigger fault handler")
    func nilNotificationObject_doesNotTriggerFaultHandler() {
        let sessionID = ObjectIdentifier(self.session)
        #expect(shouldHandleSessionFault(notificationObject: nil, sessionID: sessionID) == false)
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

// MARK: - L5 setup helper

private struct LiveCaptureSetup {
    let source: CameraSource
    let format: CameraFormat
    let anchor: HostTimeAnchor
}

/// Builds and configures a `CameraSource` driven by the same device the product uses.
/// For `.record` role also acquires the default microphone; for `.preview` passes `nil`
/// (preview never attaches a data output, so mic hardware is irrelevant).
/// Returns the configured source, the selected format, and a fresh anchor.
///
/// Camera selection mirrors `RecordingSessionTests.pickCamera`: enumerate via
/// `DeviceDiscovery.cameras(cameraAuthorized:)` (which uses `cameraDeviceTypes` and
/// therefore covers external USB devices like the MX Brio) and honour the
/// `ONSET_L5_CAMERA_NAME` env var so the test always drives the reference camera.
/// The previous `AVCaptureDevice.default(.builtInWideAngleCamera…)` call was limited
/// to built-in devices and could never return an external camera (#129).
///
/// - Parameter role: Which lifecycle the source serves (default `.record`).
///   Pass `.preview` to build a source that suppresses data outputs and telemetry.
private func makeLiveCaptureSource(role: CaptureRole = .record) throws -> LiveCaptureSetup {
    let cameras = DeviceDiscovery.cameras(cameraAuthorized: true)

    let camera: CameraDevice
    if let nameFilter = l5CameraName() {
        guard let picked = pickCamera(from: cameras, nameFilter: nameFilter) else {
            throw L5SetupError.noCamera
        }
        camera = picked
    } else {
        guard let first = cameras.first else {
            throw L5SetupError.noCamera
        }
        camera = first
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

    let config = RecordingConfiguration.mvpDefault
    let selectedFormat = try CameraFormatSelector.pickBestFormat(
        from: camera.formats,
        minFps: Double(config.minCameraFps)
    )

    let source = CameraSource(
        cameraDevice: camera,
        format: selectedFormat,
        micDevice: micDevice,
        config: config,
        role: role
    )
    return LiveCaptureSetup(source: source, format: selectedFormat, anchor: HostTimeAnchor.now())
}

// MARK: - L5 camera helpers

nonisolated private let l5Logger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CameraSourceL5Tests"
)

/// Case-insensitive substring filter applied to discovered camera display names.
///
/// Reads `ONSET_L5_CAMERA_NAME` from the environment. When unset or empty the
/// first discovered camera is used (same behaviour as `RecordingSessionTests`).
/// When set but no camera name contains the substring, the caller throws `.noCamera`.
/// Example: `ONSET_L5_CAMERA_NAME=MX Brio` pins the Logitech MX Brio.
private func l5CameraName() -> String? {
    guard let raw = ProcessInfo.processInfo.environment["ONSET_L5_CAMERA_NAME"],
          !raw.isEmpty
    else { return nil }
    return raw
}

/// Picks a camera from `cameras` whose `AVCaptureDevice.localizedName` contains
/// `nameFilter` (case-insensitive). Returns `nil` when no match is found — the caller
/// must handle this so a mismatched filter fails loudly instead of silently verifying
/// the wrong device.
///
/// The filter uses `AVCaptureDevice` directly for the name comparison because
/// `CameraDevice` stores only `uniqueID`/`formats` (no display name — PII policy).
/// The device name is used transiently for matching only and is never logged.
///
/// - Parameters:
///   - cameras: Pre-enumerated `CameraDevice` snapshots (same list as the product uses).
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
