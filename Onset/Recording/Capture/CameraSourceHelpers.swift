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

/// Bundles the two delegate shims plus the held configuration-lock device so
/// `CameraCaptureState.running` stays a single associated value (a 3-member tuple would
/// violate the `large_tuple` rule, hence the struct rather than a third associated value).
///
/// `lockedDevice` is NOT a delegate shim: it carries the `AVCaptureDevice` whose
/// configuration lock `buildAndStartSession` acquired and intentionally holds through
/// `startRunning` for `role == .record` (so AVFoundation does not revert a 4K `activeFormat`
/// to 1080p, #265). Teardown (`releaseRunning`) reads it back to unlock. `nil` for `.preview`,
/// which releases its lock right after configuration and never holds it while running.
///
/// `AVCaptureDevice` is not `Sendable`; storing it in actor-isolated state is safe because the
/// owning `CameraSource` is an actor and the field is only read on the actor.
///
/// `nonisolated` (mirrors `SessionHandle` below): under `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` the type would otherwise be MainActor-isolated, and reading the non-Sendable
/// `lockedDevice` from `CameraSource` (a plain actor, not Main) in `releaseRunning` would cross
/// isolation. The struct is constructed and read only on the owning `CameraSource` actor and
/// never escapes it, so dropping the type-level isolation is sound and needs no `Sendable`
/// conformance. (`video`/`audio` are `@unchecked Sendable` classes, so they read fine regardless;
/// only the non-Sendable `lockedDevice` forced the change.)
nonisolated struct CameraCaptureShims {
    let video: VideoOutputShim
    let audio: AudioOutputShim
    let lockedDevice: AVCaptureDevice?
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
    DropEvent(reason: .captureDrop, source: .captureCameraVideo, count: count, detectedAt: pts)
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
    return DropEvent(reason: .captureBackpressureDrops, source: .captureCameraVideo, count: 1, detectedAt: pts)
}

/// Returns a backpressure `DropEvent` for an audio `AsyncStream.Continuation.YieldResult`.
nonisolated func audioBackpressureDropEvent(
    for yieldResult: AsyncStream<AudioSample>.Continuation.YieldResult,
    pts: CMTime
)
-> DropEvent? {
    guard case .dropped = yieldResult else { return nil }
    return DropEvent(reason: .captureBackpressureDrops, source: .captureCameraAudio, count: 1, detectedAt: pts)
}

/// Returns `true` when `frameHostTime >= sessionStart`.
///
/// Shared with `CameraSource` pure-helper tests; identical contract to `shouldKeepFrame`
/// in `ScreenSource`. Separate function name avoids a name-collision link error when both
/// files are compiled into the same target.
nonisolated func shouldKeepCameraFrame(frameHostTime: CMTime, sessionStart: CMTime) -> Bool {
    CMTimeCompare(frameHostTime, sessionStart) >= 0
}

/// Returns `true` when the capture telemetry task should be launched after `start()`.
///
/// Telemetry runs only for a `.record`-role source that actually reached `.running`.
/// On the stop()-during-start abort path `buildAndStartSession` returns normally with
/// state `.stopped` (the racing `stop()` already ran its `captureTelemetryTask?.cancel()`),
/// so telemetry must NOT start there — otherwise the task `start()` would launch is never
/// cancelled and a 1 Hz telemetry task leaks for the rest of the process lifetime (#203).
nonisolated func shouldStartCaptureTelemetry(role: CaptureRole, state: CameraCaptureState) -> Bool {
    guard case .record = role else { return false }
    guard case .running = state else { return false }
    return true
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

/// Returns `true` when a session-level notification belongs to OUR capture session.
///
/// Filters out the separate preview `CameraSource`'s session (#119).
/// Extracted from `VideoOutputShim.sessionRuntimeError(_:)` and
/// `VideoOutputShim.sessionWasInterrupted(_:)` so the filtering predicate can be
/// unit-tested without live `AVCaptureSession` or `Notification` machinery.
///
/// - Parameters:
///   - notificationObject: The object from the `Notification` (`notification.object as AnyObject?`).
///     `nil` when the notification carries no object — treated as non-matching.
///   - sessionID: The `ObjectIdentifier` of the `AVCaptureSession` this source owns.
/// - Returns: `true` only when `ObjectIdentifier(notificationObject)` equals `sessionID`.
nonisolated func shouldHandleSessionFault(notificationObject: AnyObject?, sessionID: ObjectIdentifier) -> Bool {
    guard let notificationObject else { return false }
    return ObjectIdentifier(notificationObject) == sessionID
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
