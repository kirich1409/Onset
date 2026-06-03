import AVFoundation
import os

/// Logger is Sendable; nonisolated private let avoids MainActor hop for logger calls
/// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let captureDeviceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CaptureDevicePermission"
)

/// A stateless wrapper around `AVCaptureDevice` TCC authorization for camera and microphone.
///
/// Both `currentStatus(for:)` and `requestAccess(for:)` are nonisolated: they do not
/// touch actor-isolated state and are safe to call from any isolation context.
/// `AVCaptureDevice.authorizationStatus` is documented thread-safe.
///
/// Device names are never logged; only status enum values are (PII policy).
struct CaptureDevicePermission {
    // MARK: - Status

    /// Returns the current TCC authorization status for the given media type.
    ///
    /// - Parameter mediaType: `.video` for camera, `.audio` for microphone.
    nonisolated func currentStatus(for mediaType: AVMediaType) -> PermissionStatus {
        let avStatus = AVCaptureDevice.authorizationStatus(for: mediaType)
        let status = PermissionStatus(avStatus)
        captureDeviceLogger.debug("authorizationStatus for \(mediaType.rawValue): \(status)")
        return status
    }

    // MARK: - Request

    /// Requests TCC access for the given media type, presenting the system prompt if needed.
    ///
    /// After a `denied` result the system will not show the prompt again; callers should
    /// navigate the user to System Settings instead.
    ///
    /// - Parameter mediaType: `.video` for camera, `.audio` for microphone.
    /// - Returns: `true` when access was granted.
    @discardableResult
    nonisolated func requestAccess(for mediaType: AVMediaType) async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: mediaType)
        captureDeviceLogger.info("requestAccess for \(mediaType.rawValue) → \(granted)")
        return granted
    }
}

// MARK: - AVAuthorizationStatus mapping

extension PermissionStatus {
    /// Maps `AVAuthorizationStatus` to `PermissionStatus`.
    nonisolated fileprivate init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined

        case .authorized:
            self = .authorized

        case .denied:
            self = .denied

        case .restricted:
            self = .restricted

        @unknown default:
            // Treat future unknown cases as denied to avoid granting access unexpectedly.
            self = .denied
        }
    }
}
