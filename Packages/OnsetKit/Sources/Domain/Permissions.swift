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

// MARK: - NotificationPermissionProviding

/// Domain seam for user notification authorization.
///
/// Separated from `PermissionsProviding` for two reasons:
/// 1. **Async-only status**: `UNUserNotificationCenter.notificationSettings()` is an async
///    call with no synchronous accessor, making it incompatible with `PermissionsProviding`'s
///    synchronous `status(for:)` contract.
/// 2. **Optional enhancement**: Notifications are a non-capture-critical feature — when denied,
///    error surfacing continues via the NSStatusItem indicator (#42). This seam must never be a
///    required dependency for recording to function.
///
/// Concrete implementations live in Infrastructure. Application and Presentation layers depend
/// only on this protocol — no `UserNotifications` framework import leaks beyond Infrastructure.
///
/// - Note: No sandbox entitlement is required for `UNUserNotificationCenter` on macOS;
///   the framework is available to sandboxed apps without an additional entitlement key.
public protocol NotificationPermissionProviding: Sendable {
    /// Returns the current notification authorization status without presenting a dialog.
    func authorizationStatus() async -> PermissionStatus

    /// Requests notification authorization if not yet determined, then returns the resulting status.
    ///
    /// The alert and sound options are hardcoded in the Infrastructure implementation —
    /// `UNAuthorizationOptions` does not cross the Domain boundary.
    ///
    /// On a thrown error (e.g. system refusal), the error is logged as a warning and `.denied`
    /// is returned immediately — re-reading the status after a thrown request could return
    /// `.notDetermined` on a fresh install, which would violate the conservative-fallback contract.
    func requestAuthorization() async -> PermissionStatus
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
