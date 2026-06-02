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
        // When status resolves to denied/authorized, the awaiting latch is ignored.
        let screenNotDetermined = self.permissions.screenStatus == .notDetermined
        if screenNotDetermined, effective.cameraAvailable, effective.microphoneAvailable {
            return "ждём запись экрана"
        }
        if self.permissions.screenStatus == .denied || self.permissions.screenStatus == .restricted {
            return "запись экрана заблокирована"
        }
        if !effective.microphoneAvailable, effective.cameraAvailable, effective.screenAvailable {
            return "остался микрофон"
        }
        return "нужно выдать три разрешения"
    }

    /// Whether the denied-screen red banner should be visible.
    var showDeniedScreenBanner: Bool {
        self.permissions.screenStatus == .denied || self.permissions.screenStatus == .restricted
    }

    /// Whether a graceful "Продолжить без экрана" option is available.
    var canContinueWithoutScreen: Bool {
        let effective = self.permissions.effectivePermissions
        return effective.cameraAvailable && !effective.screenAvailable
    }

    /// Whether a graceful "Записать без звука" option is available.
    var canRecordWithoutAudio: Bool {
        let effective = self.permissions.effectivePermissions
        return effective.canRecord && !effective.microphoneAvailable
    }

    /// Whether the primary «Продолжить» button is enabled.
    /// Enabled when at least one video source is available.
    var canContinue: Bool {
        self.permissions.effectivePermissions.canRecord
    }

    // MARK: - Screen recording actions

    /// Opens System Settings → Screen Recording and marks the card as awaiting.
    func openScreenRecordingSettings() {
        self.permissions.openScreenRecordingSettings()
        onboardingLogger.info("Opened screen recording settings; entering awaiting state")
        self.isAwaitingScreen = true
    }

    /// Calls `CGRequestScreenCaptureAccess()` once (one-shot — never in a loop).
    /// Transitions card to awaiting state so the screen-recording card shows "Ожидание…".
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

    // MARK: - Settings deep-link pass-through

    /// Exposes the service's settings openers to view-layer button actions.
    ///
    /// Read-only pass-through: avoids leaking the concrete service type while keeping
    /// settings navigation actions within the VM's jurisdiction.
    var permissionsService: any PermissionsProviding {
        self.permissions
    }

    // MARK: - Refresh (called on scene active to catch revoke-in-Settings)

    func refresh() {
        self.permissions.refresh()
        onboardingLogger.debug("Status refreshed")
    }
}
