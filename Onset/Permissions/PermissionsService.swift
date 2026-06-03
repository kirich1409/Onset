import AppKit
import AVFoundation
import CoreGraphics
import os

/// Logger is Sendable; nonisolated private let avoids MainActor hop for logger calls
/// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let serviceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "PermissionsService"
)

/// The production source of truth for all three TCC permissions.
///
/// `@Observable` ensures SwiftUI views observe status changes automatically.
/// All mutable state lives on `@MainActor` (inherited from `SWIFT_DEFAULT_ACTOR_ISOLATION`).
///
/// The polling loop exposes a `Task`-based start/cancel contract: the caller (Stage 5
/// composition root / onboarding VM) starts the loop when onboarding opens and cancels
/// the returned task when onboarding closes, preventing background polling when not needed.
@Observable
@MainActor
final class PermissionsService: PermissionsProviding {
    // MARK: - Settings URLs (avoids force-unwrap at call sites)

    private static let cameraSettingsURL: URL = {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            fatalError("PermissionsService: invalid camera settings URL constant")
        }
        return url
    }()

    private static let microphoneSettingsURL: URL = {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            fatalError("PermissionsService: invalid microphone settings URL constant")
        }
        return url
    }()

    // MARK: - Polling interval

    /// Minimum delay between screen-status polls (1 second per spec constraint).
    private static let pollInterval: Duration = .seconds(1)

    // MARK: - System wrappers (injected for testability)

    private let screenPermission: ScreenRecordingPermission
    private let capturePermission: CaptureDevicePermission
    private let relauncher: AppRelauncher

    // MARK: - Published statuses

    private(set) var screenStatus: PermissionStatus
    private(set) var cameraStatus: PermissionStatus
    private(set) var microphoneStatus: PermissionStatus

    // MARK: - Computed

    var effectivePermissions: EffectivePermissions {
        EffectivePermissions.compute(
            screen: self.screenStatus,
            camera: self.cameraStatus,
            microphone: self.microphoneStatus
        )
    }

    var progress: Int {
        self.effectivePermissions.authorizedCount
    }

    var allGranted: Bool {
        self.screenStatus == .authorized &&
            self.cameraStatus == .authorized &&
            self.microphoneStatus == .authorized
    }

    // MARK: - Device display names

    /// Localized name of the default video capture device.
    /// `AVCaptureDevice.default(for:)` is safe to call on any thread (documented thread-safe).
    /// Never logged — display only, per PII policy.
    nonisolated var defaultCameraName: String? {
        AVCaptureDevice.default(for: .video)?.localizedName
    }

    /// Localized name of the default audio capture device.
    /// `AVCaptureDevice.default(for:)` is safe to call on any thread (documented thread-safe).
    /// Never logged — display only, per PII policy.
    nonisolated var defaultMicrophoneName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Human-readable resolution of the main display ("W×H" in native pixels).
    /// Uses `CGDisplayCopyDisplayMode` + `CGDisplayMode.pixelWidth/pixelHeight` (macOS 10.8+,
    /// current Swift API as verified on macOS 26). Returns `nil` when no mode is available.
    /// Never logged — display only, per PII policy.
    nonisolated var primaryDisplayDescription: String? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        return "\(mode.pixelWidth)×\(mode.pixelHeight)"
    }

    // MARK: - Init

    init(
        screenPermission: ScreenRecordingPermission = ScreenRecordingPermission(),
        capturePermission: CaptureDevicePermission = CaptureDevicePermission(),
        relauncher: AppRelauncher = AppRelauncher()
    ) {
        self.screenPermission = screenPermission
        self.capturePermission = capturePermission
        self.relauncher = relauncher

        // Snapshot current statuses at init time.
        self.screenStatus = screenPermission.currentStatus()
        self.cameraStatus = capturePermission.currentStatus(for: .video)
        self.microphoneStatus = capturePermission.currentStatus(for: .audio)

        serviceLogger.info("PermissionsService init — screen: \(self.screenStatus)")
        serviceLogger.info("camera: \(self.cameraStatus), mic: \(self.microphoneStatus)")
    }

    // MARK: - Refresh

    func refresh() {
        let newScreen = self.screenPermission.currentStatus()
        let newCamera = self.capturePermission.currentStatus(for: .video)
        let newMic = self.capturePermission.currentStatus(for: .audio)

        serviceLogger.debug("refresh — screen: \(newScreen), camera: \(newCamera), mic: \(newMic)")

        self.screenStatus = newScreen
        self.cameraStatus = newCamera
        self.microphoneStatus = newMic
    }

    // MARK: - Requests

    func requestCamera() async {
        serviceLogger.info("Requesting camera access")
        await self.capturePermission.requestAccess(for: .video)
        self.cameraStatus = self.capturePermission.currentStatus(for: .video)
        serviceLogger.info("Camera status after request: \(self.cameraStatus)")
    }

    func requestMicrophone() async {
        serviceLogger.info("Requesting microphone access")
        await self.capturePermission.requestAccess(for: .audio)
        self.microphoneStatus = self.capturePermission.currentStatus(for: .audio)
        serviceLogger.info("Microphone status after request: \(self.microphoneStatus)")
    }

    func requestScreenRecording() {
        serviceLogger.info("Calling CGRequestScreenCaptureAccess (one-shot)")
        self.screenPermission.requestAccess()
        // Status does not change synchronously on macOS — polling will pick it up.
    }

    // MARK: - Deep-links

    func openScreenRecordingSettings() {
        self.screenPermission.openSettings()
    }

    func openCameraSettings() {
        NSWorkspace.shared.open(Self.cameraSettingsURL)
        serviceLogger.info("Opened Camera settings")
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(Self.microphoneSettingsURL)
        serviceLogger.info("Opened Microphone settings")
    }

    // MARK: - Polling

    /// Starts the background screen-status polling loop.
    ///
    /// The loop:
    /// 1. Sleeps for ``pollInterval``.
    /// 2. Checks `CGPreflightScreenCaptureAccess()`.
    /// 3. If access just became `true` → triggers a relaunch via `AppRelauncher`.
    /// 4. Updates `screenStatus` on `@MainActor` via `self`.
    ///
    /// Cancellation is cooperative: `Task.sleep` throws `CancellationError` and the loop exits.
    /// The caller must cancel the returned `Task` when polling is no longer needed.
    @discardableResult
    func startScreenPolling() -> Task<Void, Never> {
        serviceLogger.info("Screen polling started")
        return Task { [weak self] in
            await self?.runPollingLoop()
        }
    }

    func checkScreenStatusNow() {
        let previous = self.screenStatus
        let newStatus = self.screenPermission.currentStatus()
        serviceLogger.debug("Manual check — screen: \(newStatus)")
        self.screenStatus = newStatus

        // Use the shared front-edge predicate so detection is identical to the polling loop.
        if AppRouter.shouldTriggerRelaunch(previous: previous, current: newStatus) {
            serviceLogger.info("Screen recording access detected (manual check) — triggering relaunch")
            self.relauncher.relaunchIfNeeded()
        }
    }

    // MARK: - Private polling implementation

    private func runPollingLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                // CancellationError — exit cleanly.
                serviceLogger.debug("Screen polling cancelled")
                break
            }

            // Cooperative cancellation check before doing any work.
            guard !Task.isCancelled else { break }

            let previous = self.screenStatus
            let newStatus = self.screenPermission.currentStatus()
            self.screenStatus = newStatus

            // Use the shared front-edge predicate (same as checkScreenStatusNow).
            if AppRouter.shouldTriggerRelaunch(previous: previous, current: newStatus) {
                serviceLogger.info("Screen recording access detected via polling — triggering relaunch")
                self.relauncher.relaunchIfNeeded()
                // Screen is the only polled permission; nothing left to poll once granted.
                break
            }
        }
        serviceLogger.info("Screen polling stopped")
    }
}
