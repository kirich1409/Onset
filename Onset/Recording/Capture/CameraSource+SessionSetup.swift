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

        // TEMP-LOG: #105 — verify syncClock identity (nil session clock → host clock fallback
        // means USB-mic PTS may drift relative to expected host-time anchor).
        let syncClockIsNil = session.synchronizationClock == nil
        let hostClock = CMClockGetHostTimeClock()
        // CFEqual compares CoreFoundation object identity/equality; used instead of === because
        // CMClock is a CF type bridged to Swift as a class — direct pointer compare may differ.
        let syncIsHost = CFEqual(syncClock, hostClock)
        let syncTime = CMClockGetTime(syncClock)
        let hostTime = CMClockGetTime(hostClock)
        // swiftlint:disable:next no_magic_numbers
        let clockDeltaMicros = Int((CMTimeGetSeconds(syncTime) - CMTimeGetSeconds(hostTime)) * 1_000_000)
        cameraSourceLogger.notice(
            // swiftlint:disable:next line_length
            "[audio#105-clk] sessionSyncClockNil=\(syncClockIsNil, privacy: .public) syncIsHostClock=\(syncIsHost, privacy: .public) clockDeltaMicros=\(clockDeltaMicros, privacy: .public)"
        )

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

    /// Performs `beginConfiguration` / addInputs / `lockForConfiguration` / setActiveFormat
    /// / `commitConfiguration`. Throws on any failure.
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
        let targetFps = Double(self.config.minCameraFps)
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
        device.unlockForConfiguration()
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
