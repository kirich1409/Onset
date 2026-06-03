import AVFoundation
import CoreMedia
import os

// MARK: - VideoOutputShim

/// Bridges `AVCaptureVideoDataOutput` callbacks into the `frames` and `drops` streams.
///
/// `@unchecked Sendable` rationale:
/// - All stored `let` fields (continuations, sessionStart, syncClock, onDisconnect) are
///   immutable after `init`.
/// - `didLogBufferAnomaly` is `nonisolated(unsafe) var`, confined exclusively to `videoQueue`
///   (a serial queue). That queue is the synchronization mechanism.
final class VideoOutputShim: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionStart: CMTime
    private let syncClock: CMClock
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation
    private let onDisconnect: @Sendable () async -> Void
    /// The `uniqueID` of the camera device this shim was configured for.
    /// Used to filter `wasDisconnectedNotification` to the correct device only (B1).
    private let cameraUniqueID: String

    /// Rate-limiting flag for buffer-anomaly error logs.
    /// `nonisolated(unsafe)`: confined to `videoQueue` (serial). That queue is the lock.
    nonisolated(unsafe) var didLogBufferAnomaly = false

    // nonisolated: overrides @MainActor inference (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor)
    nonisolated init(
        sessionStart: CMTime,
        syncClock: CMClock,
        framesContinuation: AsyncStream<VideoFrame>.Continuation,
        dropsContinuation: AsyncStream<DropEvent>.Continuation,
        onDisconnect: @escaping @Sendable () async -> Void,
        cameraUniqueID: String
    ) {
        self.sessionStart = sessionStart
        self.syncClock = syncClock
        self.framesContinuation = framesContinuation
        self.dropsContinuation = dropsContinuation
        self.onDisconnect = onDisconnect
        self.cameraUniqueID = cameraUniqueID
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let rawPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = toHostTime(pts: rawPts, from: self.syncClock)
        guard shouldKeepCameraFrame(frameHostTime: pts, sessionStart: self.sessionStart) else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            // `unsafe`: STRICT_MEMORY_SAFETY=YES — nonisolated(unsafe) requires this keyword.
            // Safety: read+write confined to videoQueue (serial); that queue is the lock.
            if unsafe !self.didLogBufferAnomaly {
                unsafe self.didLogBufferAnomaly = true
                cameraSourceLogger.error("Video sample has no image buffer — pts: \(pts.value)/\(pts.timescale)")
            }
            return
        }
        let frame = VideoFrame(pixelBuffer: pixelBuffer, ptsHostTime: pts, isHoldRepeat: false)
        if let dropEvent = cameraBackpressureDropEvent(for: self.framesContinuation.yield(frame), pts: pts) {
            self.dropsContinuation.yield(dropEvent)
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let rawPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = toHostTime(pts: rawPts, from: self.syncClock)
        self.dropsContinuation.yield(captureDropEvent(pts: pts))
        // .info: capture-level drops are production-visible events; .debug is stripped in
        // release builds and leaves sustained backpressure drops invisible in the field.
        cameraSourceLogger.info("Video frame dropped by AVCapture — pts: \(pts.value)/\(pts.timescale)")
    }

    // MARK: - Device disconnect

    @objc
    nonisolated func deviceDidDisconnect(_ notification: Notification) {
        // Only react when the disconnected device is the camera this shim belongs to.
        // Without this check, unplugging a microphone or any other capture device fires
        // handleCameraDisconnect and terminates the camera recording (violates AC-12).
        guard (notification.object as? AVCaptureDevice)?.uniqueID == self.cameraUniqueID else {
            return
        }
        Task { await self.onDisconnect() }
    }
}

// MARK: - AudioOutputShim

/// Bridges `AVCaptureAudioDataOutput` callbacks into the `audioSamples` and `drops` streams.
///
/// `@unchecked Sendable` rationale: all stored `let` fields are immutable after `init`;
/// no mutable state.
final class AudioOutputShim: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionStart: CMTime
    private let syncClock: CMClock
    private let audioSamplesContinuation: AsyncStream<AudioSample>.Continuation
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    // nonisolated: overrides @MainActor inference
    nonisolated init(
        sessionStart: CMTime,
        syncClock: CMClock,
        audioSamplesContinuation: AsyncStream<AudioSample>.Continuation,
        dropsContinuation: AsyncStream<DropEvent>.Continuation
    ) {
        self.sessionStart = sessionStart
        self.syncClock = syncClock
        self.audioSamplesContinuation = audioSamplesContinuation
        self.dropsContinuation = dropsContinuation
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let rawPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = toHostTime(pts: rawPts, from: self.syncClock)
        guard shouldKeepCameraFrame(frameHostTime: pts, sessionStart: self.sessionStart) else {
            return
        }
        let sample = AudioSample(sampleBuffer: sampleBuffer, ptsHostTime: pts)
        if let dropEvent = audioBackpressureDropEvent(
            for: self.audioSamplesContinuation.yield(sample),
            pts: pts
        ) {
            self.dropsContinuation.yield(dropEvent)
        }
    }
}

// MARK: - CameraSourceError

/// Internal errors used to wrap `RecordingError.captureSetupFailed`.
nonisolated enum CameraSourceError: Error {
    case deviceNotFound
    case micNotFound
    case cannotAddInput
    case sessionDidNotStart
    /// `AVCaptureSession.canAddOutput` returned `false` for the video data output.
    /// The session started (camera input was accepted) but the video delegate was never
    /// attached — `start()` would return `.running` while silently delivering zero frames.
    case cannotAddVideoOutput
    /// `AVCaptureSession.canAddOutput` returned `false` for the audio data output,
    /// even though a microphone device was requested.
    case cannotAddAudioOutput
}
