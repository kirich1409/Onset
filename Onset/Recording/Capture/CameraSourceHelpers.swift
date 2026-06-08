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

/// Returns `true` when a session runtime-error code represents a terminal camera-access loss
/// that should finalize the camera stream.
///
/// Only `.applicationIsNotAuthorizedToUseDevice` qualifies: it is the exact macOS error code
/// emitted when TCC permission is revoked while the session is running. All other codes are
/// non-access-loss conditions and must not trigger a false finalize.
///
/// `AVCaptureSessionInterruptionReasonKey` is `API_UNAVAILABLE(macos)`, so reason-based
/// mapping from `wasInterruptedNotification` is not viable on macOS — this runtime-error
/// path is the macOS-accessible signal for TCC revoke. See AC-12 / issue #69.
///
/// - Parameter errorCode: The `AVError.Code` extracted from the session runtime-error
///   notification's `userInfo[AVCaptureSessionErrorKey]`, or `nil` when the key is absent
///   or the value is not an `NSError`.
/// - Returns: `true` only for the `.applicationIsNotAuthorizedToUseDevice` TCC-revoke code;
///   `false` for all other codes and for `nil`.
nonisolated func isTerminalSessionRuntimeError(errorCode: AVError.Code?) -> Bool {
    errorCode == .applicationIsNotAuthorizedToUseDevice
}

/// Computes the inter-frame delivery gap in milliseconds between two consecutive camera PTS values.
///
/// Returns `nil` on the first delivery (no previous timestamp available), so the gap metric
/// is only recorded starting from the second frame — matching the guard in `VideoOutputShim`.
///
/// Negative deltas (PTS discontinuity from device reconnect or clock anomaly) are clamped to
/// zero so `DurationAccumulator` averages/maxima are not corrupted by a decrement.
///
/// Extracted for testability: the pure computation is exercisable without live AVFoundation or
/// actor machinery.
///
/// - Parameters:
///   - previousDeliverySec: Host-time seconds of the previous frame, or `nil` for the first frame.
///   - currentDeliverySec: Host-time seconds of the current frame.
/// - Returns: Gap in milliseconds (≥ 0), or `nil` when `previousDeliverySec` is `nil`.
nonisolated func cameraDeliveryGapMs(
    previousDeliverySec: Double?,
    currentDeliverySec: Double
)
-> Double? {
    guard let prev = previousDeliverySec else { return nil }
    // Negative PTS delta (device reconnect / clock discontinuity) is clamped to zero,
    // mirroring the tick-lag call site policy.
    // swiftlint:disable:next no_magic_numbers
    return max(0, currentDeliverySec - prev) * 1000
}
