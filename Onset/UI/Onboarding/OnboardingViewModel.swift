import os
import SwiftUI

// MARK: - Logger

/// Sendable; nonisolated avoids MainActor hop under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let onboardingLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "OnboardingViewModel"
)

// MARK: - OnboardingViewModel

/// Drives the onboarding screen state.
///
/// Derives all card statuses from `PermissionsProviding` — never caches status snapshots
/// in stored properties, so `@Observable` propagation flows through to the views correctly
/// and revoking a permission in System Settings is detected on the next `refresh()` call.
///
/// **Polling lifecycle:** start `startPolling()` when the onboarding view appears;
/// the returned `Task` must be cancelled when the view disappears. Use `.task { … }` so
/// Swift handles structured cancellation automatically.
@Observable
@MainActor
final class OnboardingViewModel {
    // MARK: - Transient screen-awaiting state (VM layer only — not in PermissionStatus)

    /// `true` while screen-recording has been requested and the polling loop is in flight.
    ///
    /// The "Ожидание…" card state (per spec) is a UI concept that lives here, not in
    /// `PermissionStatus` — the domain enum stays a clean TCC-status mirror.
    private(set) var isAwaitingScreen = false

    // MARK: - Camera/mic requesting guards

    /// Prevents double-tapping «Разрешить» for camera while the system prompt is visible.
    private(set) var isRequestingCamera = false
    /// Prevents double-tapping «Разрешить» for microphone while the system prompt is visible.
    private(set) var isRequestingMicrophone = false

    // MARK: - Dependencies

    /// Injected at construction. Never read system APIs directly.
    @ObservationIgnored
    private let permissions: any PermissionsProviding

    // MARK: - Init

    init(permissions: any PermissionsProviding) {
        self.permissions = permissions
    }

    // MARK: - Derived status passthrough

    // These computed properties deliberately read from `permissions` (not local copies),
    // so each read inside a SwiftUI body registers as an observation dependency on the
    // underlying @Observable PermissionsService. Revoking a permission and refreshing
    // will propagate through here to the view.

    var screenStatus: PermissionStatus {
        self.permissions.screenStatus
    }

    var cameraStatus: PermissionStatus {
        self.permissions.cameraStatus
    }

    var microphoneStatus: PermissionStatus {
        self.permissions.microphoneStatus
    }

    var effectivePermissions: EffectivePermissions {
        self.permissions.effectivePermissions
    }

    // MARK: - Device display names (for authorized card subtitles — never log these)

    /// Localized name of the default camera, or `nil`.  Used in the authorized camera card.
    var defaultCameraName: String? {
        self.permissions.defaultCameraName
    }

    /// Localized name of the default microphone, or `nil`. Used in the authorized mic card.
    var defaultMicrophoneName: String? {
        self.permissions.defaultMicrophoneName
    }

    /// Human-readable resolution of the main display. Used in the authorized screen card.
    var primaryDisplayDescription: String? {
        self.permissions.primaryDisplayDescription
    }

    var progress: Int {
        self.permissions.progress
    }

    // MARK: - Progress hint text

    /// Human-readable hint for the "N из 3 · <hint>" progress bar.
    var progressHintText: String {
        let effective = self.permissions.effectivePermissions
        if self.permissions.allGranted {
            return "все разрешения активны"
        }
        // "Ожидание…" hint applies while screen is notDetermined and we're actively polling.
        // Screen has no real denied state (CGPreflight is Bool-only), so .denied/.restricted
        // are treated the same as .notDetermined for hint purposes.
        let screenNotDetermined = self.permissions.screenStatus != .authorized
        if screenNotDetermined, effective.cameraAvailable, effective.microphoneAvailable {
            return "ждём запись экрана"
        }
        if !effective.microphoneAvailable, effective.cameraAvailable, effective.screenAvailable {
            return "остался микрофон"
        }
        return "нужно выдать три разрешения"
    }

    /// Whether a graceful "Продолжить без экрана" option is available.
    var canContinueWithoutScreen: Bool {
        self.permissions.effectivePermissions.cameraOnlyAvailable
    }

    /// Whether a graceful "Записать без звука" option is available.
    var canRecordWithoutAudio: Bool {
        self.permissions.effectivePermissions.videoWithoutAudioAvailable
    }

    /// Whether the primary «Продолжить» button is enabled.
    /// Enabled when at least one video source is available.
    var canContinue: Bool {
        self.permissions.effectivePermissions.canRecord
    }

    // MARK: - Screen recording actions

    /// Calls `CGRequestScreenCaptureAccess()` once (registers Onset in the TCC list),
    /// then opens System Settings → Screen Recording and marks the card as awaiting.
    ///
    /// `CGRequestScreenCaptureAccess()` must be called at least once before the app appears
    /// in System Settings → Screen Recording; without it the user opens Settings and Onset
    /// is not in the list to toggle. The call is idempotent after the first invocation.
    func openScreenRecordingSettings() {
        // One-shot registration: ensures Onset appears in the Screen Recording list.
        self.permissions.requestScreenRecording()
        self.permissions.openScreenRecordingSettings()
        onboardingLogger.info("Registered Onset in TCC list; opened Screen Recording settings; entering awaiting state")
        self.isAwaitingScreen = true
    }

    /// Calls `CGRequestScreenCaptureAccess()` once (one-shot — never in a loop).
    /// Transitions card to awaiting state so the screen-recording card shows "Ожидание…".
    ///
    /// This method remains available for callers that need only the TCC registration step
    /// without opening Settings (e.g. composition root probes).
    func requestScreenRecording() {
        self.permissions.requestScreenRecording()
        onboardingLogger.info("Requested screen recording access (one-shot)")
        self.isAwaitingScreen = true
    }

    // MARK: - Camera / mic actions

    func requestCamera() async {
        guard !self.isRequestingCamera else { return }
        self.isRequestingCamera = true
        await self.permissions.requestCamera()
        self.isRequestingCamera = false
        onboardingLogger.info("Camera request completed; status: \(self.permissions.cameraStatus)")
    }

    func requestMicrophone() async {
        guard !self.isRequestingMicrophone else { return }
        self.isRequestingMicrophone = true
        await self.permissions.requestMicrophone()
        self.isRequestingMicrophone = false
        onboardingLogger.info("Microphone request completed; status: \(self.permissions.microphoneStatus)")
    }

    // MARK: - «Проверить снова» action

    /// Triggers an immediate one-shot status check (the explicit refresh button).
    func checkNow() {
        self.permissions.checkScreenStatusNow()
        onboardingLogger.info("Manual check triggered")
    }

    // MARK: - Polling lifecycle

    /// Starts the background screen-status polling loop.
    ///
    /// Returns the `Task` driving the loop. The caller must cancel it when polling is no
    /// longer needed — use `.task { … withTaskCancellationHandler … }` for structured
    /// cancellation so the loop stops when the view disappears.
    func startPolling() -> Task<Void, Never> {
        onboardingLogger.info("Starting screen polling via OnboardingViewModel")
        return self.permissions.startScreenPolling()
    }

    // MARK: - Settings deep-links

    func openCameraSettings() {
        self.permissions.openCameraSettings()
        onboardingLogger.info("Opened camera settings")
    }

    func openMicrophoneSettings() {
        self.permissions.openMicrophoneSettings()
        onboardingLogger.info("Opened microphone settings")
    }

    // MARK: - Refresh (called on scene active to catch revoke-in-Settings)

    func refresh() {
        self.permissions.refresh()
        onboardingLogger.debug("Status refreshed")
    }
}
