import AVFoundation
import CoreMedia

// MARK: - CameraCaptureState

/// Lifecycle state of a `CameraSource` actor.
///
/// Replaces two independent optionals to eliminate representable invalid intermediate states.
/// Transitioning `.idle → .starting` synchronously before the first `await` in `start()`
/// closes the actor-reentrancy window (same pattern as `ScreenSource`).
enum CameraCaptureState {
    case idle
    case starting
    case running(session: AVCaptureSession, shims: CameraCaptureShims)
    case stopped
}

// MARK: - CameraCaptureShims

/// Bundles the two delegate shims so `CameraCaptureState.running` stays a single associated value.
///
/// Avoids a 3-member tuple which would violate the `large_tuple` rule.
struct CameraCaptureShims {
    let video: VideoOutputShim
    let audio: AudioOutputShim
}

// MARK: - SessionHandle

/// A `@unchecked Sendable` wrapper that carries an `AVCaptureSession` reference across
/// actor and MainActor boundaries for preview-layer construction.
///
/// `AVCaptureSession` is not `Sendable`. The `@unchecked` annotation is sound because:
/// - `AVCaptureSession` documents internal thread-safety: `beginConfiguration`/
///   `commitConfiguration` serialise mutations; `startRunning`/`stopRunning` may be
///   called from any thread.
/// - `SessionHandle` is handed from the actor to MainActor **once** during `start()`,
///   after `startRunning()` completes. At that point no mutable configuration operations
///   remain — the actor never calls `beginConfiguration` again during the lifetime of this
///   handle. MainActor uses it only to create `AVCaptureVideoPreviewLayer(session:)`.
/// - Mutations and preview-layer creation therefore never race.
nonisolated struct SessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
}

// MARK: - Testable pure helpers

/// Returns a capture-level `DropEvent` when the video output delegate fires `didDrop`.
///
/// Extracted as a `nonisolated` function so the mapping can be unit-tested without
/// live AVFoundation or actor machinery.
nonisolated func captureDropEvent(pts: CMTime, count: Int = 1) -> DropEvent {
    DropEvent(reason: .captureDrop, count: count, detectedAt: pts)
}

/// Returns a backpressure `DropEvent` for the given `AsyncStream.Continuation.YieldResult`,
/// or `nil` when the frame was enqueued or the stream is terminated.
///
/// Extracted for testability — mirrors `backpressureDropEvent` in `ScreenSource`.
nonisolated func cameraBackpressureDropEvent(
    for yieldResult: AsyncStream<VideoFrame>.Continuation.YieldResult,
    pts: CMTime
)
-> DropEvent? {
    guard case .dropped = yieldResult else { return nil }
    return DropEvent(reason: .encoderBackpressureDrops, count: 1, detectedAt: pts)
}

/// Returns a backpressure `DropEvent` for an audio `AsyncStream.Continuation.YieldResult`.
nonisolated func audioBackpressureDropEvent(
    for yieldResult: AsyncStream<AudioSample>.Continuation.YieldResult,
    pts: CMTime
)
-> DropEvent? {
    guard case .dropped = yieldResult else { return nil }
    return DropEvent(reason: .encoderBackpressureDrops, count: 1, detectedAt: pts)
}

/// Returns `true` when `frameHostTime >= sessionStart`.
///
/// Shared with `CameraSource` pure-helper tests; identical contract to `shouldKeepFrame`
/// in `ScreenSource`. Separate function name avoids a name-collision link error when both
/// files are compiled into the same target.
nonisolated func shouldKeepCameraFrame(frameHostTime: CMTime, sessionStart: CMTime) -> Bool {
    CMTimeCompare(frameHostTime, sessionStart) >= 0
}

/// Converts `pts` from `sourceClock` to the host clock.
///
/// When `sourceClock` is identical to the host clock (`CMClockGetHostTimeClock()`),
/// `CMSyncConvertTime` returns the input unchanged — the conversion is a no-op. This
/// function always converts so the caller never needs to branch on clock identity.
///
/// Extracted for testability: the pure wrapper is exercisable without a live session.
nonisolated func toHostTime(pts: CMTime, from sourceClock: CMClock) -> CMTime {
    CMSyncConvertTime(pts, from: sourceClock, to: CMClockGetHostTimeClock())
}

/// Determines the permission decision from a TCC authorization status pair.
///
/// - Returns: `true` when both video and audio are `.authorized` and capture may proceed.
nonisolated func isCaptureAuthorized(
    video: AVAuthorizationStatus,
    audio: AVAuthorizationStatus
)
-> Bool {
    video == .authorized && audio == .authorized
}

/// Returns `true` when the disconnected device matches the camera this source was configured for.
///
/// Extracted from `VideoOutputShim.deviceDidDisconnect(_:)` so the filtering predicate can be
/// unit-tested without live `AVCaptureDevice` or `Notification` machinery.
///
/// - Parameters:
///   - notificationDeviceID: The `uniqueID` of the device that fired the disconnect notification
///     (`(notification.object as? AVCaptureDevice)?.uniqueID`). `nil` when the notification
///     object is not an `AVCaptureDevice` — treated as non-matching.
///   - cameraID: The `uniqueID` of the camera this source is recording from.
/// - Returns: `true` only when `notificationDeviceID` equals `cameraID`.
nonisolated func shouldHandleDisconnect(notificationDeviceID: String?, cameraID: String) -> Bool {
    notificationDeviceID == cameraID
}
