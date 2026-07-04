import AVFoundation
import CoreMedia

// MARK: - CameraSource suspension observation (#222)

extension CameraSource {
    /// Builds the delegate shims for `session`.
    ///
    /// `lockedDevice` is derived from `self.role` rather than taken as a separate parameter
    /// (keeps the parameter count under the lint limit): bundled into the shims only for
    /// `.record` — preview passes `nil` (it already released the configuration lock). Teardown
    /// reads it back to unlock via `releaseRunning()`.
    func makeShims(
        session: AVCaptureSession,
        device: AVCaptureDevice,
        sessionStart: CMTime,
        syncClock: CMClock,
        callbacks: CameraSessionCallbacks
    )
    -> CameraCaptureShims {
        let video = VideoOutputShim(
            sessionStart: sessionStart,
            syncClock: syncClock,
            framesContinuation: self.framesContinuation,
            dropsContinuation: self.dropsContinuation,
            onDisconnect: callbacks.onDisconnect,
            onSessionFault: callbacks.onSessionFault,
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
        let suspensionObservation = self.makeSuspensionObservation(device: device, callbacks: callbacks)
        return CameraCaptureShims(
            video: video,
            audio: audio,
            lockedDevice: self.role == .record ? device : nil,
            suspensionObservation: suspensionObservation
        )
    }

    /// Registers KVO on `isSuspended` for the recording device, routing a suspension into the
    /// SAME terminal path as a session fault (`onSessionFault`) rather than a new parallel
    /// lifecycle.
    ///
    /// macOS posts no `NotificationCenter` event for camera suspension (e.g. clamshell lid
    /// close while an external display/keyboard keep the system awake) — `wasDisconnectedNotification`
    /// does not fire, `AVCaptureSession.isRunning` stays `true`, and frames simply stop. `isSuspended`
    /// is KVO-observable only (mirrors `DeviceAvailabilityObserver.makeSuspensionObservations`, which
    /// watches the same property for the device picker).
    ///
    /// `@Sendable` and does NOT capture `device`: the closure reads `observedDevice.uniqueID`
    /// (a `String`, extracted synchronously, matching `VideoOutputShim.deviceDidDisconnect`'s
    /// pattern of reading the `Notification` synchronously before crossing into `Task`) and
    /// otherwise only touches the already-`Sendable` `cameraID` and `callbacks`.
    ///
    /// Built-in-mic clamshell behavior (issue #222, Q4) is deliberately NOT handled here — camera
    /// only; tracked separately (#259-adjacent).
    func makeSuspensionObservation(
        device: AVCaptureDevice,
        callbacks: CameraSessionCallbacks
    )
    -> NSKeyValueObservation {
        let cameraID = self.cameraDevice.uniqueID
        return device.observe(\.isSuspended, options: [.new]) { @Sendable observedDevice, change in
            guard shouldHandleSuspension(
                isSuspended: change.newValue ?? false,
                notificationDeviceID: observedDevice.uniqueID,
                cameraID: cameraID
            ) else {
                return
            }
            Task { await callbacks.onSessionFault("camera suspended (e.g. notebook lid closed)") }
        }
    }
}
