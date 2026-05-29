import Foundation

// MARK: - PermissionKind

/// Identifies which TCC permission a query or request targets.
public enum PermissionKind: Sendable, Equatable, CaseIterable {
    /// macOS Screen Recording TCC permission.
    ///
    /// Controlled via CoreGraphics: `CGPreflightScreenCaptureAccess()` for status,
    /// `CGRequestScreenCaptureAccess()` for requesting. There is no AVFoundation-style
    /// `requestAccess` for screen recording; the system dialog appears once on first
    /// `CGRequestScreenCaptureAccess()` call (or first `SCShareableContent` access).
    case screenRecording

    /// Camera TCC permission (AVCaptureDevice, media type `.video`).
    case camera

    /// Microphone TCC permission (AVCaptureDevice, media type `.audio`).
    case microphone
}

// MARK: - PermissionStatus

/// The current authorization state for a TCC permission.
public enum PermissionStatus: Sendable, Equatable {
    /// The user has not yet been asked to grant this permission.
    case notDetermined

    /// The user has granted the permission.
    case authorized

    /// The user has explicitly denied the permission.
    case denied

    /// The permission is restricted by system policy (MDM, parental controls, etc.)
    /// and cannot be changed by the user.
    case restricted
}

// MARK: - PermissionsProviding

/// Domain seam for TCC permission checks and requests.
///
/// Allows Application and Presentation layers to query and request permissions
/// without importing any system frameworks (CoreGraphics, AVFoundation) directly.
/// Concrete implementations live in Infrastructure.
///
/// ## Screen Recording specifics
/// macOS does not expose a four-state authorization status for Screen Recording the
/// way AVFoundation does for camera/mic. `CGPreflightScreenCaptureAccess()` returns
/// a `Bool` with no way to distinguish `.notDetermined` from `.denied` via preflight
/// alone. The Infrastructure implementation works around this OS limitation using a
/// persisted "have we ever requested" flag in `UserDefaults`:
/// - Before `request(.screenRecording)` is called → `status` returns `.notDetermined`
/// - After `request(.screenRecording)` has been called at least once:
///   `true → .authorized`, `false → .denied`
/// This allows the `configuring→ready` gate (#36) to correctly detect first-run state
/// rather than misreporting `.denied` on a fresh install.
public protocol PermissionsProviding: Sendable {
    /// Returns the current authorization status for `kind` synchronously.
    ///
    /// This is a non-mutating preflight — it does not trigger a system dialog.
    func status(for kind: PermissionKind) -> PermissionStatus

    /// Requests authorization for `kind` if not yet determined, then returns the resulting status.
    ///
    /// For `.camera` and `.microphone`, uses `AVCaptureDevice.requestAccess(for:)` which
    /// presents a standard TCC dialog when `.notDetermined`. For `.screenRecording`, calls
    /// `CGRequestScreenCaptureAccess()` which prompts once; the real dialog may also appear
    /// on first `SCShareableContent` access, but calling this method first is recommended.
    ///
    /// This method is safe to call even if the permission is already `.authorized` or `.denied`;
    /// no dialog will appear in those cases and the current status is returned immediately.
    func request(_ kind: PermissionKind) async -> PermissionStatus
}
