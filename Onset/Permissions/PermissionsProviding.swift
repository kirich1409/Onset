import AVFoundation

/// Abstracts all three TCC permissions for testability.
///
/// `PermissionsService` is the production implementation. Tests supply a `FakePermissionsService`.
/// Stage 4 (OnboardingViewModel) and Stage 5 (composition root / routing) depend on this protocol.
@MainActor
protocol PermissionsProviding: AnyObject {
    // MARK: - Current statuses

    /// The current screen-recording permission status.
    var screenStatus: PermissionStatus { get }
    /// The current camera permission status.
    var cameraStatus: PermissionStatus { get }
    /// The current microphone permission status.
    var microphoneStatus: PermissionStatus { get }

    // MARK: - Computed views

    /// The effective recording modes derived from the three statuses.
    var effectivePermissions: EffectivePermissions { get }

    /// The number of authorized permissions (0–3). The "N из 3" progress value.
    var progress: Int { get }

    /// `true` when all three permissions are `.authorized`.
    var allGranted: Bool { get }

    // MARK: - Mutation

    /// Refreshes all three statuses from their system sources.
    func refresh()

    // MARK: - Requests

    /// Presents the system prompt for camera access (no-op if already determined).
    func requestCamera() async

    /// Presents the system prompt for microphone access (no-op if already determined).
    func requestMicrophone() async

    /// Calls `CGRequestScreenCaptureAccess()` exactly once (one-shot; never in a loop).
    func requestScreenRecording()

    // MARK: - Deep-links

    /// Opens System Settings → Privacy → Screen Recording.
    func openScreenRecordingSettings()

    /// Opens System Settings → Privacy → Camera.
    func openCameraSettings()

    /// Opens System Settings → Privacy → Microphone.
    func openMicrophoneSettings()

    // MARK: - Polling

    /// Starts the background polling loop that re-checks screen status at ~1 s intervals.
    ///
    /// The polling loop auto-stops when the `Task` started here is cancelled.
    /// Callers should cancel the returned task (or use structured concurrency) when
    /// the onboarding window closes.
    ///
    /// - Returns: The `Task` driving the loop so the caller can cancel it.
    @discardableResult
    func startScreenPolling() -> Task<Void, Never>

    /// Triggers an immediate one-shot refresh of screen status outside the polling interval
    /// (the "Проверить снова" explicit refresh button).
    func checkScreenStatusNow()
}
