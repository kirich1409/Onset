import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - CameraSource session setup

extension CameraSource {
    // MARK: - Session setup (decomposed to keep functions ≤ 40 lines)

    func buildAndStartSession(anchor: HostTimeAnchor) async throws {
        let session = AVCaptureSession()
        let device = try self.resolveCameraDevice()

        // Hold the device configuration lock from BEFORE configureSession through to
        // either the preview unlock or the .record hand-off to teardown. Releasing the
        // lock before startRunning() makes AVFoundation reconcile activeFormat back to a
        // session default, silently reverting a 4K format to 1080p (#265, OBS format-path).
        //
        // INVARIANT (load-bearing — build does NOT enforce it): there must be NO `await`
        // between this lockForConfiguration() and the transition to `.running`. The body
        // below is synchronous from the actor's perspective (the only `await`s live inside
        // the @Sendable onDisconnect/onSessionFault closures, which run later). An `await`
        // here would stretch the lock across an actor suspension and open reentrancy /
        // deadlock with stop().
        do {
            try device.lockForConfiguration()
        } catch {
            cameraSourceLogger.error("lockForConfiguration failed: \(error)")
            throw RecordingError.captureSetupFailed(error)
        }
        // Single ownership flag. Cleared at exactly one of: the preview unlock below, or the
        // `.record` hand-off to teardown. The defer fires only if neither happened (an error
        // before either point) → exactly one unlock on every path, including preview-throw.
        var locked = true
        defer { if locked { device.unlockForConfiguration() } }

        try self.configureSession(session, device: device)

        // Preview never holds the lock while running: release immediately after configuration
        // (still before startRunning, so no revert risk for preview's ≤1080p format). Record
        // keeps the lock — ownership moves to teardown at the `.running` hand-off below.
        if self.role == .preview {
            device.unlockForConfiguration()
            locked = false
        }

        // Capture the synchronisation clock AFTER commitConfiguration so the session
        // has adopted whatever clock it will use (commonly the audio device clock).
        let syncClock = session.synchronizationClock ?? CMClockGetHostTimeClock()

        let onDisconnect: @Sendable ()
            async -> Void = { [weak self] in
                await self?.handleCameraDisconnect()
            }
        let onSessionFault: @Sendable (String)
            async -> Void = { [weak self] reason in
                await self?.handleCameraSessionFault(reason: reason)
            }

        // The locked device is bundled into the shims only for `.record`; preview passes nil
        // (it already released the lock). Teardown reads it back to unlock via releaseRunning().
        let shims = self.makeShims(
            session: session,
            sessionStart: anchor.anchorTime,
            syncClock: syncClock,
            onDisconnect: onDisconnect,
            onSessionFault: onSessionFault,
            lockedDevice: self.role == .record ? device : nil
        )
        try self.attachOutputs(to: session, shims: shims)

        session.startRunning()
        guard session.isRunning else {
            let err = CameraSourceError.sessionDidNotStart
            cameraSourceLogger.error("AVCaptureSession did not start")
            throw RecordingError.captureSetupFailed(err)
        }

        // Close the stop()-during-.starting race: if stop() ran while buildAndStartSession
        // was suspended (before .running was set), captureState is now .stopped. Continuing
        // would overwrite it with .running and create a zombie session whose streams are
        // already finished. Observer is not yet registered, so no removal is needed here.
        // The lock (if record still holds it) is released by the `defer` above — `locked`
        // is still true on this abort path.
        guard case .starting = self.captureState else {
            session.stopRunning()
            cameraSourceLogger.info("Capture aborted — stop() called during startup")
            return
        }

        // Observers registered after startRunning so a failed-start path never needs to remove them.
        self.registerDisconnectObserver(shims: shims, session: session)
        self.captureState = .running(session: session, shims: shims)
        // Hand the lock's ownership to teardown: from here releaseRunning() in stop() /
        // disconnect / fault is responsible for unlocking, so the defer must NOT fire.
        locked = false
        cameraSourceLogger.info(
            "Capture started — dims: \(self.format.pixelWidth)×\(self.format.pixelHeight)"
        )
    }

    /// Resolves and validates the configured camera `AVCaptureDevice` before session setup.
    ///
    /// Lifted out of `addCameraInput` so `buildAndStartSession` can acquire the configuration
    /// lock on the resolved device before `configureSession` and hold it through `startRunning`
    /// (#265). The device is passed down into `configureSession` / `addCameraInput` /
    /// `makeCameraInput` / `activateFormat` rather than re-resolved.
    ///
    /// - Throws: `RecordingError.captureSetupFailed` with `.deviceNotFound` (no device for the
    ///   configured `uniqueID`) or `.deviceSuspended` (lid closed after the picker populated).
    func resolveCameraDevice() throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice(uniqueID: self.cameraDevice.uniqueID) else {
            cameraSourceLogger.error("Camera device not found for configured uniqueID")
            throw RecordingError.captureSetupFailed(CameraSourceError.deviceNotFound)
        }
        // Backstop for the selection→start race: discovery already filters suspended
        // devices, but the lid can close after the picker was populated. A suspended
        // camera starts a session that delivers zero frames — refuse instead.
        guard !device.isSuspended else {
            cameraSourceLogger.error("Camera device is suspended — refusing capture setup")
            throw RecordingError.captureSetupFailed(CameraSourceError.deviceSuspended)
        }
        return device
    }

    /// Performs `beginConfiguration` / addInputs / setActiveFormat / `commitConfiguration`.
    /// Operates on the already-locked `device` resolved by `buildAndStartSession`; the
    /// configuration lock is acquired and released by the caller, not here. Throws on any failure.
    func configureSession(_ session: AVCaptureSession, device: AVCaptureDevice) throws {
        session.beginConfiguration()
        try self.addCameraInput(to: session, device: device)
        if let mic = self.micDevice {
            try self.addMicInput(mic: mic, to: session)
        }
        session.commitConfiguration()
    }

    func addCameraInput(to session: AVCaptureSession, device: AVCaptureDevice) throws {
        let input = try self.makeCameraInput(device)
        guard session.canAddInput(input) else {
            cameraSourceLogger.error("Cannot add camera input to session")
            throw RecordingError.captureSetupFailed(CameraSourceError.cannotAddInput)
        }
        session.addInput(input)
    }

    func makeCameraInput(_ device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        let targetFps = Double(self.config.minCameraFps)
        guard let liveFormat = self.findMatchingFormat(device: device) else {
            cameraSourceLogger.error(
                "No live format matches selected snapshot — dims: \(self.format.pixelWidth)×\(self.format.pixelHeight)"
            )
            throw RecordingError.noSuitableCameraFormat
        }
        self.activateFormat(liveFormat, fps: targetFps, on: device)
        return input
    }

    /// Finds the live `AVCaptureDevice.Format` that matches the pre-selected `CameraFormat` snapshot.
    ///
    /// The snapshot holds dims + fps only; re-querying by `uniqueID` is required because
    /// the `AVCaptureDevice.Format` reference is not `Sendable` and must not be stored.
    func findMatchingFormat(device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let targetW = self.format.pixelWidth
        let targetH = self.format.pixelHeight
        let targetFps = Double(self.config.minCameraFps)
        return device.formats.first { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let fpsOk = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFps }
            return dims.width == targetW && dims.height == targetH && fpsOk
        }
    }

    /// Sets `activeFormat` and the min/max frame durations on an ALREADY-LOCKED device.
    ///
    /// The configuration lock is owned by `buildAndStartSession` (acquired before
    /// `configureSession`, held through `startRunning` for `.record`) — this helper must not
    /// lock or unlock, or it would drop the lock before start and let AVFoundation revert the
    /// 4K format (#265).
    func activateFormat(
        _ liveFormat: AVCaptureDevice.Format,
        fps: Double,
        on device: AVCaptureDevice
    ) {
        device.activeFormat = liveFormat

        // Use the frame duration from the matching AVFrameRateRange rather than
        // constructing a CMTime from the target fps. AVFoundation rejects a duration
        // (e.g. 1/30) that does not exactly equal the rational stored in the range
        // (e.g. 1000000/30000030 on Tundra / Continuity cameras), throwing
        // NSInvalidArgumentException from setActiveVideoMinFrameDuration.
        // Picking the range whose maxFrameRate best satisfies minFps gives us the
        // exact CMTime representation the device expects.
        let qualifiedRanges = liveFormat.videoSupportedFrameRateRanges.filter { $0.maxFrameRate >= fps }
        let bestRange = qualifiedRanges.min { abs($0.maxFrameRate - fps) < abs($1.maxFrameRate - fps) }
        if let bestRange {
            device.activeVideoMinFrameDuration = bestRange.minFrameDuration
            device.activeVideoMaxFrameDuration = bestRange.minFrameDuration
        } else {
            // No range satisfies the fps target — this should never happen because
            // findMatchingFormat already filtered by maxFrameRate ≥ targetFps. Fall
            // back to the constructed duration to preserve the pre-existing behaviour
            // rather than silently skipping the configuration step.
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        }
    }

    func addMicInput(mic: MicrophoneDevice, to session: AVCaptureSession) throws {
        guard let micAVDevice = AVCaptureDevice(uniqueID: mic.uniqueID) else {
            cameraSourceLogger.error("Microphone device not found for configured uniqueID")
            throw RecordingError.captureSetupFailed(CameraSourceError.micNotFound)
        }
        let micInput = try AVCaptureDeviceInput(device: micAVDevice)
        guard session.canAddInput(micInput) else {
            cameraSourceLogger.error("Cannot add microphone input to session")
            throw RecordingError.captureSetupFailed(CameraSourceError.cannotAddInput)
        }
        session.addInput(micInput)
    }

    func makeShims(
        session: AVCaptureSession,
        sessionStart: CMTime,
        syncClock: CMClock,
        onDisconnect: @escaping @Sendable () async -> Void,
        onSessionFault: @escaping @Sendable (String) async -> Void,
        lockedDevice: AVCaptureDevice?
    )
    -> CameraCaptureShims {
        let video = VideoOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            framesContinuation: self.framesContinuation,
            dropsContinuation: self.dropsContinuation,
            onDisconnect: onDisconnect,
            onSessionFault: onSessionFault,
            cameraUniqueID: self.cameraDevice.uniqueID,
            captureSessionID: ObjectIdentifier(session),
            rateLock: self.captureRateLock
        )
        let audio = AudioOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            audioSamplesContinuation: self.audioSamplesContinuation,
            dropsContinuation: self.dropsContinuation
        )
        return CameraCaptureShims(video: video, audio: audio, lockedDevice: lockedDevice)
    }

    func attachOutputs(to session: AVCaptureSession, shims: CameraCaptureShims) throws {
        // Preview renders via AVCaptureVideoPreviewLayer straight from the session input;
        // a data output would yield frames nobody consumes (constant overflow, issue #119).
        guard self.role == .record else { return }
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        // Late frames are discarded by the OS, surfaced as didDrop → DropEvent(.captureDrop).
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            cameraSourceLogger.error("Cannot add video data output to session")
            throw RecordingError.captureSetupFailed(CameraSourceError.cannotAddVideoOutput)
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(shims.video, queue: self.videoQueue)

        if self.micDevice != nil {
            let audioOutput = AVCaptureAudioDataOutput()
            // Pin the capture output to a fixed LPCM format. Without this, some USB microphones
            // (e.g. MX Brio) deliver the first few buffers in the device's native int16 interleaved
            // format, then CoreAudio switches mid-stream to float32 non-interleaved. The mid-stream
            // format change faults AVAssetWriterInput (AAC) with -12737 / -11800, killing both
            // writers. Pinning here prevents the switch; values mirror FileWriter's AAC target
            // for consistency by construction. See #105.
            audioOutput.audioSettings = Self.audioOutputSettings(
                sampleRate: self.config.audioSampleRate,
                channelCount: self.config.audioChannelCount
            )
            // Log the actually-applied settings: AVCaptureAudioDataOutput.audioSettings is a
            // best-effort API — the framework may ignore or adjust the requested values.
            // .debug: stripped in release builds; safe to log the full dict at this level.
            cameraSourceLogger.debug(
                "Audio output settings applied: \(String(describing: audioOutput.audioSettings), privacy: .public)"
            )
            guard session.canAddOutput(audioOutput) else {
                cameraSourceLogger.error("Cannot add audio data output to session")
                throw RecordingError.captureSetupFailed(CameraSourceError.cannotAddAudioOutput)
            }
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(shims.audio, queue: self.audioQueue)
        }
    }

    func registerDisconnectObserver(shims: CameraCaptureShims, session: AVCaptureSession) {
        // AVCaptureDeviceWasDisconnected is posted on the main thread; the shim captures
        // only the notification and dispatches to its async closure.
        NotificationCenter.default.addObserver(
            shims.video,
            selector: #selector(VideoOutputShim.deviceDidDisconnect(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
        // Session-level fault notifications use `object: session` so NotificationCenter
        // delivers only notifications for our specific session. The shim also guards by
        // ObjectIdentifier as defense-in-depth against the preview session (#119).
        NotificationCenter.default.addObserver(
            shims.video,
            selector: #selector(VideoOutputShim.sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            shims.video,
            selector: #selector(VideoOutputShim.sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
    }
}
