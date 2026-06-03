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
        self.attachOutputs(to: session, shims: shims)

        session.startRunning()
        guard session.isRunning else {
            let err = CameraSourceError.sessionDidNotStart
            cameraSourceLogger.error("AVCaptureSession did not start")
            throw RecordingError.captureSetupFailed(err)
        }

        // Observer registered after startRunning so a failed-start path never needs to remove it.
        self.registerDisconnectObserver(shims: shims)
        self.captureState = .running(session: session, shims: shims)
        // nonisolated(unsafe): written here (actor context), read later on MainActor for preview.
        // Safety: written once before any MainActor read; no concurrent writes after this point.
        unsafe self.sessionHandle = SessionHandle(session: session)
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
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
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
            onDisconnect: onDisconnect
        )
        let audio = AudioOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            audioSamplesContinuation: self.audioSamplesContinuation,
            dropsContinuation: self.dropsContinuation
        )
        return CameraCaptureShims(video: video, audio: audio)
    }

    func attachOutputs(to session: AVCaptureSession, shims: CameraCaptureShims) {
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        // Late frames are discarded by the OS, surfaced as didDrop → DropEvent(.captureDrop).
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(shims.video, queue: self.videoQueue)
        } else {
            cameraSourceLogger.error("Cannot add video data output to session")
        }

        if self.micDevice != nil {
            let audioOutput = AVCaptureAudioDataOutput()
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutput.setSampleBufferDelegate(shims.audio, queue: self.audioQueue)
            } else {
                cameraSourceLogger.error("Cannot add audio data output to session")
            }
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
