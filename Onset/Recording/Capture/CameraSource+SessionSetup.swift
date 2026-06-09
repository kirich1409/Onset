import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - CameraSource session setup

extension CameraSource {
    // MARK: - Session setup (decomposed to keep functions ≤ 40 lines)

    func buildAndStartSession(anchor: HostTimeAnchor) async throws {
        let session = AVCaptureSession()
        try self.configureSession(session)

        // Capture the synchronisation clock AFTER commitConfiguration so the session
        // has adopted whatever clock it will use (commonly the audio device clock).
        let syncClock = session.synchronizationClock ?? CMClockGetHostTimeClock()

        let onDisconnect: @Sendable () async -> Void = { [weak self] in
            await self?.handleCameraDisconnect()
        }

        let shims = self.makeShims(
            sessionStart: anchor.anchorTime,
            syncClock: syncClock,
            onDisconnect: onDisconnect
        )
        try self.attachOutputs(to: session, shims: shims)

        session.startRunning()
        guard session.isRunning else {
            let err = CameraSourceError.sessionDidNotStart
            cameraSourceLogger.error("AVCaptureSession did not start")
            throw RecordingError.captureSetupFailed(err)
        }

        // DIAGNOSTIC #113 (post-startRunning): log the live fps state so L5 can confirm
        // auto-exposure has not re-extended the frame duration after the session starts.
        // Re-acquire the device by uniqueID — AVCaptureDevice references are not Sendable.
        if let liveDevice = AVCaptureDevice(uniqueID: self.cameraDevice.uniqueID) {
            let dims = CMVideoFormatDescriptionGetDimensions(liveDevice.activeFormat.formatDescription)
            cameraSourceLogger.notice(
                // swiftlint:disable:next line_length
                "Post-startRunning #113: \(dims.width)×\(dims.height) autoFREnabled=\(liveDevice.isAutoVideoFrameRateEnabled) dur=\(liveDevice.activeVideoMaxFrameDuration.value)/\(liveDevice.activeVideoMaxFrameDuration.timescale)"
            )
        }

        // Close the stop()-during-.starting race: if stop() ran while buildAndStartSession
        // was suspended (before .running was set), captureState is now .stopped. Continuing
        // would overwrite it with .running and create a zombie session whose streams are
        // already finished. Observer is not yet registered, so no removal is needed here.
        guard case .starting = self.captureState else {
            session.stopRunning()
            cameraSourceLogger.info("Capture aborted — stop() called during startup")
            return
        }

        // Observer registered after startRunning so a failed-start path never needs to remove it.
        self.registerDisconnectObserver(shims: shims)
        self.captureState = .running(session: session, shims: shims)
        cameraSourceLogger.info(
            "Capture started — dims: \(self.format.pixelWidth)×\(self.format.pixelHeight)"
        )
    }

    /// Performs `beginConfiguration` / addInputs / setActiveFormat + fps lock / `commitConfiguration`.
    /// Throws on any failure.
    func configureSession(_ session: AVCaptureSession) throws {
        session.beginConfiguration()
        try self.addCameraInput(to: session)
        if let mic = self.micDevice {
            try self.addMicInput(mic: mic, to: session)
        }
        session.commitConfiguration()
    }

    func addCameraInput(to session: AVCaptureSession) throws {
        guard let device = AVCaptureDevice(uniqueID: self.cameraDevice.uniqueID) else {
            cameraSourceLogger.error("Camera device not found for configured uniqueID")
            throw RecordingError.captureSetupFailed(CameraSourceError.deviceNotFound)
        }
        let input = try self.makeCameraInput(device)
        guard session.canAddInput(input) else {
            cameraSourceLogger.error("Cannot add camera input to session")
            throw RecordingError.captureSetupFailed(CameraSourceError.cannotAddInput)
        }
        session.addInput(input)
    }

    func makeCameraInput(_ device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        let targetFps = Double(self.targetFps)
        guard let liveFormat = self.findMatchingFormat(device: device) else {
            cameraSourceLogger.error(
                "No live format matches selected snapshot — dims: \(self.format.pixelWidth)×\(self.format.pixelHeight)"
            )
            throw RecordingError.noSuitableCameraFormat
        }
        try self.activateFormat(liveFormat, fps: targetFps, on: device)
        return input
    }

    /// Finds the live `AVCaptureDevice.Format` that matches the pre-selected `CameraFormat` snapshot.
    ///
    /// The snapshot holds dims + fps only; re-querying by `uniqueID` is required because
    /// the `AVCaptureDevice.Format` reference is not `Sendable` and must not be stored.
    /// The fps filter uses `self.targetFps` (the resolved 60 or 30) so that a 1080p60 target
    /// selects the 60fps-capable format rather than a 30fps-capable one with the same resolution.
    func findMatchingFormat(device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let targetW = self.format.pixelWidth
        let targetH = self.format.pixelHeight
        let targetFps = Double(self.targetFps)
        return device.formats.first { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let fpsOk = fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= targetFps }
            return dims.width == targetW && dims.height == targetH && fpsOk
        }
    }

    /// Sets `device.activeFormat` to `liveFormat` and locks the fps, with DIAGNOSTIC #113 logging.
    ///
    /// fps lock sequence:
    /// 1. BEFORE: log `isAutoVideoFrameRateSupported` and `isAutoVideoFrameRateEnabled`.
    /// 2. If `isAutoVideoFrameRateSupported`, disable `isAutoVideoFrameRateEnabled`.
    ///    When enabled, setting `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration`
    ///    throws `NSInvalidArgumentException` (ObjC exception, not catchable by Swift).
    /// 3. AFTER disable: log that enabled is now false.
    /// 4. Reset frame durations to `.invalid` to clear any AE-extended value.
    /// 5. Set `activeVideoMin/MaxFrameDuration` to the exact CMTime from
    ///    `videoSupportedFrameRateRanges` (synthetic rationals like 1/60 are rejected).
    /// 6. AFTER lock: log `activeVideoMaxFrameDuration`.
    func activateFormat(
        _ liveFormat: AVCaptureDevice.Format,
        fps: Double,
        on device: AVCaptureDevice
    ) throws {
        do {
            try device.lockForConfiguration()
        } catch {
            cameraSourceLogger.error("lockForConfiguration failed: \(error)")
            throw RecordingError.captureSetupFailed(error)
        }
        device.activeFormat = liveFormat

        // DIAGNOSTIC #113 (before autoFR disable).
        let autoFRSupported = liveFormat.isAutoVideoFrameRateSupported
        let autoFREnabled = device.isAutoVideoFrameRateEnabled
        cameraSourceLogger.notice(
            // swiftlint:disable:next line_length
            "DIAGNOSTIC #113 pre-lock: autoFRSupported=\(autoFRSupported) autoFREnabled=\(autoFREnabled)"
        )

        if autoFRSupported {
            // Disable auto-frame-rate BEFORE touching min/maxFrameDuration.
            // When isAutoVideoFrameRateEnabled is true, those setters throw
            // NSInvalidArgumentException from ObjC — Swift cannot catch ObjC exceptions.
            device.isAutoVideoFrameRateEnabled = false
            cameraSourceLogger.notice(
                "DIAGNOSTIC #113 post-autoFR-disable: autoFREnabled=\(device.isAutoVideoFrameRateEnabled)"
            )
        }

        // Reset to .invalid first to clear any AE-extended value.
        device.activeVideoMinFrameDuration = .invalid
        device.activeVideoMaxFrameDuration = .invalid

        // Derive the exact CMTime from the matching AVFrameRateRange — AVFoundation rejects
        // a duration (e.g. 1/60) that does not exactly equal the rational stored in the range
        // (e.g. 1000000/60000060 on some cameras), throwing NSInvalidArgumentException.
        let minFrameDuration = self.deriveFpsLockDuration(activeFormat: liveFormat, targetFps: fps)
        device.activeVideoMinFrameDuration = minFrameDuration
        device.activeVideoMaxFrameDuration = minFrameDuration

        // DIAGNOSTIC #113 (after lock).
        cameraSourceLogger.notice(
            // swiftlint:disable:next line_length
            "DIAGNOSTIC #113 post-lock: dur=\(device.activeVideoMaxFrameDuration.value)/\(device.activeVideoMaxFrameDuration.timescale) dims=\(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width)×\(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).height)"
        )

        device.unlockForConfiguration()
    }

    /// Derives the exact `CMTime` for the target fps from the active format's frame-rate ranges.
    /// Clamps to the achievable max when `targetFps` exceeds the format's `maxFrameRate`.
    func deriveFpsLockDuration(
        activeFormat: AVCaptureDevice.Format,
        targetFps: Double
    )
    -> CMTime {
        let ranges = activeFormat.videoSupportedFrameRateRanges
        // Among ranges whose maxFrameRate ≥ targetFps, pick the closest match.
        let qualifiedRanges = ranges.filter { $0.maxFrameRate >= targetFps }
        if let bestRange = qualifiedRanges.min(by: {
            abs($0.maxFrameRate - targetFps) < abs($1.maxFrameRate - targetFps)
        }) {
            return bestRange.minFrameDuration
        }
        // targetFps exceeds the format's maximum — clamp to the highest available rate.
        if let highestRange = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            cameraSourceLogger.warning(
                "targetFps \(targetFps) exceeds format max — clamping to \(highestRange.maxFrameRate)"
            )
            return highestRange.minFrameDuration
        }
        // No ranges at all — construct a fallback duration (should never happen for a valid format).
        return CMTime(value: 1, timescale: CMTimeScale(targetFps))
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
        sessionStart: CMTime,
        syncClock: CMClock,
        onDisconnect: @escaping @Sendable () async -> Void
    )
    -> CameraCaptureShims {
        let video = VideoOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            framesContinuation: self.framesContinuation,
            dropsContinuation: self.dropsContinuation,
            onDisconnect: onDisconnect,
            cameraUniqueID: self.cameraDevice.uniqueID,
            rateLock: self.captureRateLock
        )
        let audio = AudioOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            audioSamplesContinuation: self.audioSamplesContinuation,
            dropsContinuation: self.dropsContinuation
        )
        return CameraCaptureShims(video: video, audio: audio)
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

    func registerDisconnectObserver(shims: CameraCaptureShims) {
        // AVCaptureDeviceWasDisconnected is posted on the main thread; the shim captures
        // only the notification and dispatches to its async closure.
        NotificationCenter.default.addObserver(
            shims.video,
            selector: #selector(VideoOutputShim.deviceDidDisconnect(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }
}
