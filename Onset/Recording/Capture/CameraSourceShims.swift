import AVFoundation
import CoreMedia
import os

// MARK: - VideoOutputShim

/// Bridges `AVCaptureVideoDataOutput` callbacks into the `frames` and `drops` streams.
///
/// `@unchecked Sendable` rationale:
/// - All stored `let` fields (continuations, sessionStart, syncClock, onDisconnect,
///   onSessionFault, cameraUniqueID, captureSessionID) are immutable after `init`.
/// - `didLogBufferAnomaly` is `nonisolated(unsafe) var`, confined exclusively to `videoQueue`
///   (a serial queue). That queue is the synchronization mechanism.
final class VideoOutputShim: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionStart: CMTime
    private let syncClock: CMClock
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation
    private let onDisconnect: @Sendable () async -> Void
    /// Called when the `AVCaptureSession` this shim belongs to faults (runtime error or
    /// interruption). `reason` is a concise diagnostic string (no PII).
    private let onSessionFault: @Sendable (_ reason: String) async -> Void
    /// The `uniqueID` of the camera device this shim was configured for.
    /// Used to filter `wasDisconnectedNotification` to the correct device only (B1).
    private let cameraUniqueID: String
    /// Identity of the `AVCaptureSession` this shim was created for.
    /// Used to filter session-level notifications to OUR session only — the app
    /// runs a separate preview `CameraSource` with its own session (#119).
    private let captureSessionID: ObjectIdentifier

    /// Rate-limiting flag for buffer-anomaly error logs.
    /// `nonisolated(unsafe)`: confined to `videoQueue` (serial). That queue is the lock.
    nonisolated(unsafe) var didLogBufferAnomaly = false

    /// Host-time seconds of the previous frame presented to `captureOutput`, used to compute
    /// the camera PTS inter-arrival gap fed to `recordDeliveryGap`.
    ///
    /// Updated on every `captureOutput` callback (including frames dropped by the pipeline);
    /// the gap metric measures device delivery cadence, not pipeline throughput.
    ///
    /// `nonisolated(unsafe)`: confined to `videoQueue` (serial). That queue is the lock.
    nonisolated(unsafe) var lastDeliveryHostTimeSec: Double?

    /// Per-stage cadence accumulator, shared with the owning `CameraSource` actor for flushing.
    ///
    /// `OSAllocatedUnfairLock` because `VideoOutputShim` runs on `videoQueue` (a GCD serial queue)
    /// while the flush tick runs actor-isolated — two isolation domains accessing the same struct.
    /// The lock itself is `Sendable` (value type, heap-allocated internally), so storing it as a
    /// `let` constant satisfies the `@unchecked Sendable` contract.
    let rateLock: OSAllocatedUnfairLock<StageRateAggregator>

    // nonisolated: overrides @MainActor inference (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor)
    nonisolated init(
        sessionStart: CMTime,
        syncClock: CMClock,
        framesContinuation: AsyncStream<VideoFrame>.Continuation,
        dropsContinuation: AsyncStream<DropEvent>.Continuation,
        onDisconnect: @escaping @Sendable () async -> Void,
        onSessionFault: @escaping @Sendable (_ reason: String) async -> Void,
        cameraUniqueID: String,
        captureSessionID: ObjectIdentifier,
        rateLock: OSAllocatedUnfairLock<StageRateAggregator>
    ) {
        self.sessionStart = sessionStart
        self.syncClock = syncClock
        self.framesContinuation = framesContinuation
        self.dropsContinuation = dropsContinuation
        self.onDisconnect = onDisconnect
        self.onSessionFault = onSessionFault
        self.cameraUniqueID = cameraUniqueID
        self.captureSessionID = captureSessionID
        self.rateLock = rateLock
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
        let yieldResult = self.framesContinuation.yield(frame)
        // `unsafe`: STRICT_MEMORY_SAFETY=YES — nonisolated(unsafe) requires this keyword.
        // Safety: read+write confined to videoQueue (serial); that queue is the lock.
        let ptsSeconds = CMTimeGetSeconds(pts)
        let previousDelivery = unsafe self.lastDeliveryHostTimeSec
        unsafe self.lastDeliveryHostTimeSec = ptsSeconds
        self.rateLock.withLock { aggregator in
            if case .dropped = yieldResult {
                aggregator.recordOverflow()
            } else {
                aggregator.recordFresh()
                if let gapMs = cameraDeliveryGapMs(
                    previousDeliverySec: previousDelivery,
                    currentDeliverySec: ptsSeconds
                ) {
                    aggregator.recordDeliveryGap(durationMs: gapMs)
                }
            }
        }
        if let dropEvent = cameraBackpressureDropEvent(for: yieldResult, pts: pts) {
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
        self.rateLock.withLock { $0.recordCaptureDrop() }
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
        // Predicate extracted to shouldHandleDisconnect() for unit-testability (T-A).
        guard shouldHandleDisconnect(
            notificationDeviceID: (notification.object as? AVCaptureDevice)?.uniqueID,
            cameraID: self.cameraUniqueID
        ) else {
            return
        }
        Task { await self.onDisconnect() }
    }

    // MARK: - Session fault

    /// Handles `AVCaptureSession.runtimeErrorNotification`.
    ///
    /// Filters to OUR session to avoid reacting to the separate preview session (#119).
    /// The error is read synchronously before the `Task` so `Notification` is not
    /// captured across isolation boundaries (Swift 6 complete concurrency).
    @objc
    nonisolated func sessionRuntimeError(_ notification: Notification) {
        guard shouldHandleSessionFault(
            notificationObject: notification.object as AnyObject?,
            sessionID: self.captureSessionID
        ) else {
            return
        }
        // AVCaptureSessionErrorKey carries an NSError; log its numeric code to avoid
        // embedding a localizedDescription that could contain a device display name.
        let reason =
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                "runtime error \(error.code) (\(error.domain))"
            } else {
                "runtime error (unknown)"
            }
        Task { await self.onSessionFault(reason) }
    }

    /// Handles `AVCaptureSession.wasInterruptedNotification`.
    ///
    /// Filters to OUR session to avoid reacting to the separate preview session (#119).
    /// `AVCaptureSessionInterruptionReasonKey` and `AVCaptureSession.InterruptionReason`
    /// are iOS-only (unavailable on macOS) — the raw `Int` value from userInfo is used
    /// instead to preserve diagnostic information without referencing unavailable symbols.
    /// The reason value is read synchronously before the `Task` so `Notification` is not
    /// captured across isolation boundaries (Swift 6 complete concurrency).
    @objc
    nonisolated func sessionWasInterrupted(_ notification: Notification) {
        guard shouldHandleSessionFault(
            notificationObject: notification.object as AnyObject?,
            sessionID: self.captureSessionID
        ) else {
            return
        }
        // AVCaptureSessionInterruptionReasonKey is iOS-only; read the raw Int value
        // under the string key so macOS builds remain warning-free under warnings-as-errors.
        let reason =
            if let reasonValue = notification.userInfo?["AVCaptureSessionInterruptionReason"] as? Int {
                "interrupted (reason code \(reasonValue))"
            } else {
                "interrupted (reason unknown)"
            }
        Task { await self.onSessionFault(reason) }
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
