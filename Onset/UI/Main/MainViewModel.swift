import AVFoundation
import os
import SwiftUI

// MARK: - Logger

/// Sendable; nonisolated avoids a MainActor hop under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated let mainViewModelLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "MainViewModel"
)

// MARK: - MainViewModel

/// View model for the main recording configuration screen (#36).
///
/// Owns device discovery, camera preview lifecycle, and the AC-2 record-button logic:
/// - (a) screen is the mandatory video source (MVP); display selected → button active; camera is optional
/// - (b) mic available but NOT selected → button disabled with message
/// - (c) mic unavailable → record without audio, «без звука» indicator
/// - (d) screen permission denied → empty state (return to onboarding)
///
/// ### Preview lifecycle
/// A generation counter (`previewGeneration`) drives `.id()` on `CameraPreviewRepresentable`
/// so SwiftUI recreates the NSView — and thus the `AVCaptureVideoPreviewLayer` — whenever the
/// camera changes. The `CameraSource` actor for preview is started/stopped inside `.task(id: selectedCameraID)`.
/// Old source MUST be stopped before a new one starts to avoid device contention.
///
/// ### Camera-only recording (no screen)
/// Deferred post-MVP (decision B, issue #61). `RecordingRequest.display` is non-optional;
/// `RecordingSession` has no screen-skip branch. Screen capture is mandatory in MVP.
@Observable
@MainActor
final class MainViewModel {
    // MARK: - Injectable seams

    @ObservationIgnored
    let permissions: any PermissionsProviding

    @ObservationIgnored
    let coordinator: RecordingCoordinator

    /// Closure seam for display discovery — injectable for tests.
    @ObservationIgnored
    let discoverDisplays: (Bool) async throws -> [Display]

    /// Closure seam for camera discovery — injectable for tests.
    @ObservationIgnored
    let discoverCameras: (Bool) -> [CameraDevice]

    /// Closure seam for microphone discovery — injectable for tests.
    @ObservationIgnored
    let discoverMicrophones: (Bool) -> [MicrophoneDevice]

    /// Factory seam for `CameraSource` — injectable for tests to avoid hardware calls.
    @ObservationIgnored
    let makeCameraSource:
        (CameraDevice, CameraFormat, MicrophoneDevice?, RecordingConfiguration) -> CameraSource

    /// Test seam: when non-nil, replaces `coordinator.start(_:)` in `startRecording`.
    ///
    /// Injected by `MainViewModelTests` to spy on coordinator invocations without constructing
    /// a real `RecordingCoordinator`. The live default is `nil` — the coordinator is called directly.
    @ObservationIgnored
    var startSessionOverride: (@MainActor (RecordingRequest) async throws -> Void)?

    // MARK: - Device lists

    // internal setters — must be settable from MainViewModel+Devices.swift extension
    var displays: [Display] = []
    var cameras: [CameraDevice] = []
    var microphones: [MicrophoneDevice] = []

    // MARK: - User selections (ID-typed for Hashable Picker compatibility)

    /// The `CGDirectDisplayID` of the selected display, or `nil` when no selection.
    var selectedDisplayID: CGDirectDisplayID?

    /// The `uniqueID` of the selected camera device, or `nil` for none.
    var selectedCameraID: String?

    /// The `uniqueID` of the selected microphone device, or `nil` for none.
    var selectedMicID: String?

    // MARK: - Error state

    /// Non-nil when the most recent `record()` call failed, a validation error occurred,
    /// or device discovery failed (e.g. display list could not be loaded).
    /// Internal (not private) so `MainViewModel+Record.swift` and `MainViewModel+Devices.swift`
    /// extensions can write it.
    var recordError: String?

    /// `true` while a `record()` call is in flight.
    /// Internal (not private) so `MainViewModel+Record.swift` extension can write it.
    var isStartingRecording = false

    // MARK: - Preview state

    /// The `SessionHandle` for the live camera preview, or `nil` for placeholder.
    /// Internal (not private) so `MainViewModel+Preview.swift` extension can write it.
    var previewHandle: SessionHandle?

    /// Bumped on each camera change; drives `.id()` on the `NSViewRepresentable` wrapper
    /// to force recreation of `CameraPreviewView` (its `init` wires the layer, `updateNSView` is no-op).
    /// Internal (not private) so `MainViewModel+Preview.swift` extension can write it.
    var previewGeneration = 0

    /// The `CameraSource` actor kept alive for preview; stopped before recreation.
    /// Internal (not private) so `MainViewModel+Preview.swift` extension can write it.
    @ObservationIgnored
    var previewSource: CameraSource?

    // MARK: - Computed properties — effective permissions passthrough

    /// Drives the AC-2(d) empty state: screen permission denied → show return-to-onboarding state.
    ///
    /// Keyed on screen permission only (MVP: screen is the mandatory video source, issue #61).
    /// `EffectivePermissions.canRecord` is intentionally NOT used here — it is screen-OR-camera
    /// and would show the normal config screen even when screen is denied (misleading in MVP).
    var showNoPermissionsState: Bool {
        self.permissions.screenStatus != .authorized
    }

    /// Screen permission denied — show disabled row + link back to onboarding.
    var isScreenDenied: Bool {
        self.permissions.screenStatus != .authorized
    }

    /// Camera permission denied.
    var isCameraDenied: Bool {
        self.permissions.cameraStatus != .authorized
    }

    /// Whether microphone is available (authorized) from permissions.
    var isMicAvailable: Bool {
        self.permissions.effectivePermissions.microphoneAvailable
    }

    // MARK: - Computed properties — selected devices (resolved from ID)

    /// The display object matching `selectedDisplayID`, or `nil`.
    var selectedDisplay: Display? {
        guard let id = self.selectedDisplayID else { return nil }
        return self.displays.first { $0.displayID == id }
    }

    /// The camera device matching `selectedCameraID`, or `nil`.
    var selectedCamera: CameraDevice? {
        guard let id = self.selectedCameraID else { return nil }
        return self.cameras.first { $0.uniqueID == id }
    }

    /// The microphone device matching `selectedMicID`, or `nil`.
    var selectedMic: MicrophoneDevice? {
        guard let id = self.selectedMicID else { return nil }
        return self.microphones.first { $0.uniqueID == id }
    }

    // MARK: - AC-2 computed properties

    /// True when a valid recordable video source is selected.
    ///
    /// MVP: screen is the mandatory video source (decision B, issue #61).
    /// Requires screen permission granted AND a display resolved.
    /// Camera-only (no screen) is deferred post-MVP.
    var hasVideoSource: Bool {
        self.permissions.screenStatus == .authorized && self.selectedDisplayID != nil
    }

    /// AC-2(b): mic is available (authorized) but the user has not selected any microphone.
    var isMicAvailableButUnselected: Bool {
        self.isMicAvailable && self.selectedMicID == nil
    }

    /// AC-2(c): recording will proceed without audio.
    ///
    /// True when at least one video source is present but microphone is unavailable.
    var isRecordingWithoutAudio: Bool {
        self.hasVideoSource && !self.isMicAvailable
    }

    /// AC-2 record button enabled state.
    ///
    /// - Returns `true` when: has video source AND (mic is unavailable OR mic is selected).
    /// - Returns `false` for AC-2(b): mic available but nothing selected.
    /// - Returns `false` for AC-2(d): no video source by permissions (handled separately as empty state).
    var canRecord: Bool {
        guard self.hasVideoSource else { return false }
        // AC-2(b): block if mic is available but none selected
        guard !self.isMicAvailableButUnselected else { return false }
        return true
    }

    /// AC-2(b) inline message shown below the record button when mic is available but unselected.
    var recordDisabledReason: String? {
        guard self.hasVideoSource, self.isMicAvailableButUnselected else { return nil }
        return "Выберите аудио-вход, чтобы начать запись"
    }

    // MARK: - Device display names (resolved at UI layer via AVCaptureDevice)

    /// Human-readable label for a camera device, resolved via `AVCaptureDevice(uniqueID:)`.
    ///
    /// PII note: device names are shown in UI but never logged. Log counts only.
    func cameraLabel(for device: CameraDevice) -> String {
        AVCaptureDevice(uniqueID: device.uniqueID)?.localizedName ?? "Камера"
    }

    /// Human-readable label for a microphone device, resolved via `AVCaptureDevice(uniqueID:)`.
    func microphoneLabel(for device: MicrophoneDevice) -> String {
        AVCaptureDevice(uniqueID: device.uniqueID)?.localizedName ?? "Микрофон"
    }

    /// Human-readable description for a display (e.g. "1920×1080 @ 60 Hz").
    func displayLabel(for display: Display) -> String {
        let res = "\(display.pixelWidth)×\(display.pixelHeight)"
        guard display.refreshHz != 0.0 else { return res }
        let refreshRate = Int(display.refreshHz)
        return "\(res) @ \(refreshRate) Гц"
    }

    // MARK: - Init

    init(
        permissions: any PermissionsProviding,
        coordinator: RecordingCoordinator,
        discoverDisplays: @escaping (Bool) async throws -> [Display] = { authorized in
            try await DeviceDiscovery.displays(screenAuthorized: authorized)
        },
        discoverCameras: @escaping (Bool) -> [CameraDevice] = { authorized in
            DeviceDiscovery.cameras(cameraAuthorized: authorized)
        },
        discoverMicrophones: @escaping (Bool) -> [MicrophoneDevice] = { authorized in
            DeviceDiscovery.microphones(microphoneAuthorized: authorized)
        },
        makeCameraSource: @escaping (
            CameraDevice, CameraFormat, MicrophoneDevice?, RecordingConfiguration
        )
            -> CameraSource = { device, format, mic, config in
                CameraSource(cameraDevice: device, format: format, micDevice: mic, config: config, role: .preview)
            }
    ) {
        self.permissions = permissions
        self.coordinator = coordinator
        self.discoverDisplays = discoverDisplays
        self.discoverCameras = discoverCameras
        self.discoverMicrophones = discoverMicrophones
        self.makeCameraSource = makeCameraSource
    }
}
