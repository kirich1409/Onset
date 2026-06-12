// swiftlint:disable file_length
import AppKit
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
/// ### Camera toggle
/// `cameraEnabled` (default `true`) lets the user switch camera recording on/off (#77, #76).
/// `activeCamera` is the unified single predicate: non-nil iff `cameraEnabled == true` AND a
/// real camera is selected. Camera is NOT a factor in `canRecord` — screen is always required.
///
/// ### Preview lifecycle
/// A generation counter (`previewGeneration`) drives `.id()` on `CameraPreviewRepresentable`
/// so SwiftUI recreates the NSView — and thus the `AVCaptureVideoPreviewLayer` — whenever the
/// camera changes. The `CameraSource` actor for preview is started/stopped inside
/// `.task(id: activeCamera?.uniqueID)`. Old source MUST be stopped before a new one starts to
/// avoid device contention.
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

    /// Closure seam for the device-change event stream — injectable for tests.
    ///
    /// The live default builds a `DeviceAvailabilityObserver` whose lifetime is tied to
    /// the returned stream: its `onTermination` tears the observer down when the consuming
    /// task is cancelled (main window disappears). See `observeDeviceChanges()`.
    @ObservationIgnored
    let makeDeviceChangeStream: @MainActor () -> AsyncStream<DeviceChangeEvent>

    /// Factory seam for `CameraSource` — injectable for tests to avoid hardware calls.
    ///
    /// The default closure builds a `.preview`-role source (no data output, no telemetry);
    /// injected closures in tests may build a `.record`-role source or a fake entirely.
    @ObservationIgnored
    let makeCameraSource:
        (CameraDevice, CameraFormat, MicrophoneDevice?, RecordingConfiguration) -> CameraSource

    /// Closure seam for device-selection persistence — injectable for tests.
    ///
    /// The default closure builds a `UserDefaultsDeviceSelectionStore` backed by
    /// `.standard`. Tests inject an `InMemoryUserDefaults`-backed store via
    /// `withScopedDefaults`.
    @ObservationIgnored
    let makeStore: () -> any DeviceSelectionPersisting

    @ObservationIgnored
    private let outputFolderStore: any OutputFolderPersisting

    /// Closure seam for display-configuration-change events — injectable for tests.
    ///
    /// Live default yields `Void` on each `NSApplication.didChangeScreenParametersNotification`.
    /// Tests inject a stream driven by `AsyncStream.makeStream` for deterministic reloads.
    @ObservationIgnored
    let screenChangeEvents: () -> AsyncStream<Void>

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

    // MARK: - Persistence state

    /// When `true`, `selectedCameraID` and `selectedMicID` `didSet` observers skip
    /// persistence writes. Set to `true` around the entire device-load/restore/auto-select
    /// block in `loadCamerasAndMicrophones()` so programmatic restores do not overwrite
    /// the just-loaded record.
    @ObservationIgnored
    var isApplyingPersistedSelection = false

    // MARK: - Disconnected-device notices

    /// Human-readable name of the previously selected camera that is no longer available,
    /// or `nil` when the camera is present or was never selected.
    ///
    /// Set during device load when a saved `uniqueID` cannot be matched against the
    /// current device list. Cleared when a matching camera is found, or when the user
    /// explicitly selects a different camera.
    var disconnectedCameraName: String?

    /// Human-readable name of the previously selected microphone that is no longer available,
    /// or `nil` when the microphone is present or was never selected.
    var disconnectedMicName: String?

    // MARK: - User selections (ID-typed for Hashable Picker compatibility)

    /// The `CGDirectDisplayID` of the selected display, or `nil` when no selection.
    var selectedDisplayID: CGDirectDisplayID?

    /// The `uniqueID` of the selected camera device, or `nil` for none.
    var selectedCameraID: String? {
        didSet {
            guard !self.isApplyingPersistedSelection else { return }
            // Clear the disconnected notice when the user makes a new selection.
            self.disconnectedCameraName = nil
            self.persistCameraSelection()
        }
    }

    /// The `uniqueID` of the selected microphone device, or `nil` for none.
    var selectedMicID: String? {
        didSet {
            guard !self.isApplyingPersistedSelection else { return }
            // Clear the disconnected notice when the user makes a new selection.
            self.disconnectedMicName = nil
            let store = self.makeStore()
            if let id = self.selectedMicID {
                let name = if let device = self.microphones.first(where: { $0.uniqueID == id }) {
                    self.microphoneLabel(for: device)
                } else {
                    "Микрофон"
                }
                store.saveMicrophone(DeviceSelectionRecord(uniqueID: id, localizedName: name))
            } else {
                store.clearMicrophone()
            }
        }
    }

    // MARK: - Output folder (#225)

    /// The user-selected base output directory, or `~/Movies/Onset/` when no selection was saved.
    ///
    /// UI reads this to display the current path and offer "Show in Finder". The setter persists
    /// the new path immediately via `outputFolderStore`. Backed by `UserDefaults` (no sandbox,
    /// no security-scoped bookmark needed — Onset runs as Developer ID / direct distribution).
    var outputDirectoryURL: URL {
        didSet {
            self.outputFolderStore.saveBaseDirectory(self.outputDirectoryURL)
        }
    }

    /// Whether the camera is enabled for recording (#77, #76).
    ///
    /// When `false`: `activeCamera` is nil, no preview is shown, camera is excluded from
    /// the recording request. When flipped to `true` with no prior selection, the first
    /// available camera is auto-selected so the user gets a working default immediately.
    var cameraEnabled = true {
        didSet {
            // Auto-select first camera when re-enabling with no prior selection.
            if self.cameraEnabled {
                self.selectFirstCameraIfNeeded()
            }
            // Persist the enable/disable choice so the user's decision survives restart.
            // `persistCameraSelection` reads both `cameraEnabled` and `selectedCameraID`,
            // so it correctly writes `.disabled` here and `.enabled(record)` on re-enable.
            // Not guarded by `isApplyingPersistedSelection` — the cameraEnabled.didSet
            // path is only reached from the `.disabled` restore branch (where we explicitly
            // skip persist by staying under the guard in loadCamerasAndMicrophones).
            if !self.isApplyingPersistedSelection {
                self.persistCameraSelection()
            }
        }
    }

    // MARK: - Camera toggle computed properties

    /// The unified "camera is active" predicate: non-nil iff `cameraEnabled` AND a real camera
    /// is selected. Used as the single source of truth for preview lifecycle, recording request,
    /// and UI gating (replaces per-site checks on `selectedCamera`).
    var activeCamera: CameraDevice? {
        self.cameraEnabled ? self.selectedCamera : nil
    }

    /// True when the camera will be included in the recording.
    ///
    /// Equivalent to `activeCamera != nil`; surfaced separately for readability at call sites.
    var isCameraActive: Bool {
        self.activeCamera != nil
    }

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

    /// Human-readable label for a display (e.g. "Внешний дисплей — 3840×2160 @ 60").
    ///
    /// Delegates to ``DisplayLabelMapper/label(for:)`` — see that type for format details.
    func displayLabel(for display: Display) -> String {
        DisplayLabelMapper.label(for: display)
    }

    // MARK: - Private helpers

    /// Selects the first available camera when none is currently selected, or when the
    /// current selection no longer matches any device in `cameras` (stale id after hot-unplug).
    ///
    /// Shared by the cold-start device load (`loadCamerasAndMicrophones`) and the camera
    /// toggle re-enable path (`cameraEnabled.didSet`) so the default-selection rule lives in
    /// one place. Does not reference `cameraEnabled` — call-site guards apply that condition.
    ///
    /// Not `private` so `MainViewModel+Devices.swift` can call it from the same type.
    ///
    /// Persistence depends on the entry point:
    /// - `.noSavedSelection` branch (cold-start, under `isApplyingPersistedSelection`):
    ///   `selectedCameraID.didSet` skips the save, so the auto-selection is NOT persisted.
    ///   This avoids a false "disconnected" notice if the default camera disappears before
    ///   the user ever explicitly chose one.
    /// - `cameraEnabled.didSet` re-enable path (`isApplyingPersistedSelection` is `false`):
    ///   `selectedCameraID.didSet` runs normally and calls `persistCameraSelection()`, so
    ///   the healed selection IS persisted.
    func selectFirstCameraIfNeeded() {
        // Heal a stale id (non-nil but device no longer present) as well as the nil case.
        if let id = self.selectedCameraID, self.cameras.contains(where: { $0.uniqueID == id }) {
            return
        }
        if let first = self.cameras.first {
            self.selectedCameraID = first.uniqueID
        }
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
        makeDeviceChangeStream: @escaping @MainActor () -> AsyncStream<DeviceChangeEvent> = {
            DeviceAvailabilityObserver().events()
        },
        makeCameraSource: @escaping (
            CameraDevice, CameraFormat, MicrophoneDevice?, RecordingConfiguration
        )
            -> CameraSource = { device, format, mic, config in
                CameraSource(cameraDevice: device, format: format, micDevice: mic, config: config, role: .preview)
            },
        makeStore: @escaping () -> any DeviceSelectionPersisting = {
            UserDefaultsDeviceSelectionStore()
        },
        makeOutputFolderStore: @escaping () -> any OutputFolderPersisting = {
            UserDefaultsOutputFolderStore()
        },
        screenChangeEvents: @escaping () -> AsyncStream<Void> = {
            // Bridges didChangeScreenParametersNotification as a Void signal.
            // Async-sequence form avoids a non-Sendable observer token in @Sendable closure.
            AsyncStream { continuation in
                let task = Task {
                    let center = NotificationCenter.default
                    let name = NSApplication.didChangeScreenParametersNotification
                    for await _ in center.notifications(named: name) {
                        continuation.yield()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    ) {
        self.permissions = permissions
        self.coordinator = coordinator
        self.discoverDisplays = discoverDisplays
        self.discoverCameras = discoverCameras
        self.discoverMicrophones = discoverMicrophones
        self.makeDeviceChangeStream = makeDeviceChangeStream
        self.makeCameraSource = makeCameraSource
        self.makeStore = makeStore
        self.screenChangeEvents = screenChangeEvents

        // Create the store once; the same instance is reused in outputDirectoryURL.didSet.
        self.outputFolderStore = makeOutputFolderStore()

        // Restore the persisted base directory, falling back to ~/Movies/Onset/.
        // `RecordingOutput.directory()` is the single authoritative source for the default path.
        self.outputDirectoryURL = self.outputFolderStore.loadBaseDirectory() ?? RecordingOutput.directory()
    }
}
