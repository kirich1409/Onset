import AVFoundation
import CoreGraphics
import Foundation
@testable import Onset
import Testing

// MARK: - MainViewModelTests

// swiftlint:disable type_body_length file_length
// Rationale: covers full MainViewModel device/label/record/preview surface; extraction
// would scatter closely related AC tests across multiple files and reduce readability.

/// Tests cover `MainViewModel`'s observable behavior via `FakePermissionsService`
/// and injectable device-discovery seams.
///
/// The suite is `@MainActor` because `MainViewModel` and `FakePermissionsService`
/// are `@MainActor`-isolated.
///
/// Each `@Test` receives fresh instances via `@Suite struct` isolation — no shared
/// mutable state, parallel-safe by default.
@Suite("MainViewModel")
@MainActor
struct MainViewModelTests {
    // MARK: - Helpers

    /// Creates a `MainViewModel` with injected device lists and a fake permissions service.
    ///
    /// Both persistence stores (device-selection and output-folder) are backed by a single
    /// per-SUT `InMemoryUserDefaults` so no `.plist` files are written to
    /// `~/Library/Preferences/` during tests. Callers needing a persistence round-trip pass
    /// an explicit instance; otherwise a fresh isolated instance is used per SUT.
    private func makeSUT(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .authorized,
        microphone: PermissionStatus = .authorized,
        displays: [Display] = [],
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = [],
        defaults: InMemoryUserDefaults
    )
    -> (sut: MainViewModel, perms: FakePermissionsService) {
        let perms = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: defaults)
        }
        let sut = MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) }
        )
        return (sut, perms)
    }

    private static func makeDisplay(
        id: CGDirectDisplayID = 1,
        name: String = "Test Display",
        width: Int = 1920,
        height: Int = 1080,
        refreshHz: Double = 60
    )
    -> Display {
        Display(displayID: id, name: name, pixelWidth: width, pixelHeight: height, refreshHz: refreshHz)
    }

    private static func makeCamera(id: String = "cam-1") -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    private static func makeMic(id: String = "mic-1") -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: id)
    }

    /// A `SessionHandle` over a fresh `AVCaptureSession` for `.live(_)` fixtures (no hardware).
    private static func makeHandle() -> SessionHandle {
        SessionHandle(session: AVCaptureSession())
    }

    // MARK: - AC-1: Auto-select when exactly one display

    @Test("One display → selectedDisplayID auto-set after loadDevices (AC-1)")
    func singleDisplay_autoSelected() async {
        await withScopedDefaults { defaults in
            let display = Self.makeDisplay()
            let (sut, _) = self.makeSUT(displays: [display], defaults: defaults)

            #expect(sut.selectedDisplayID == nil)

            await sut.loadDevices()

            #expect(sut.selectedDisplayID == display.displayID)
        }
    }

    @Test("Two displays → selectedDisplayID stays nil (no auto-select)")
    func twoDisplays_noAutoSelect() async {
        await withScopedDefaults { defaults in
            let displays = [Self.makeDisplay(id: 1), Self.makeDisplay(id: 2)]
            let (sut, _) = self.makeSUT(displays: displays, defaults: defaults)

            await sut.loadDevices()

            #expect(sut.selectedDisplayID == nil)
        }
    }

    // MARK: - Camera auto-select on load

    @Test("Camera available → first camera auto-selected after loadDevices")
    func cameraAvailable_firstAutoSelected() async {
        await withScopedDefaults { defaults in
            let cam = Self.makeCamera(id: "cam-abc")
            let (sut, _) = self.makeSUT(cameras: [cam], defaults: defaults)

            await sut.loadDevices()

            #expect(sut.selectedCameraID == "cam-abc")
        }
    }

    @Test("No cameras → selectedCameraID stays nil")
    func noCameras_noAutoSelect() async {
        await withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(cameras: [], defaults: defaults)

            await sut.loadDevices()

            #expect(sut.selectedCameraID == nil)
        }
    }

    // MARK: - Mic: NO auto-select

    @Test("Microphone available → selectedMicID NOT auto-selected (spec: no mic auto-select)")
    func micAvailable_noAutoSelect() async {
        await withScopedDefaults { defaults in
            let mic = Self.makeMic(id: "mic-xyz")
            let (sut, _) = self.makeSUT(microphones: [mic], defaults: defaults)

            await sut.loadDevices()

            #expect(sut.selectedMicID == nil)
        }
    }

    // MARK: - AC-2(a): Has video source → canRecord true

    @Test("Screen authorized + display selected → canRecord true (AC-2a)")
    func screenAndDisplaySelected_canRecord() async {
        await withScopedDefaults { defaults in
            let display = Self.makeDisplay()
            let (sut, _) = self.makeSUT(microphone: .notDetermined, displays: [display], defaults: defaults)
            await sut.loadDevices()
            // screen authorized, selectedDisplayID auto-set (1 display), no mic

            #expect(sut.selectedDisplayID != nil)
            #expect(sut.hasVideoSource)
            #expect(sut.canRecord) // no mic available, so AC-2c applies — can record
        }
    }

    @Test("Camera selected, screen denied — hasVideoSource false (MVP: screen mandatory)")
    func cameraOnly_noVideoSource() async {
        await withScopedDefaults { defaults in
            let cam = Self.makeCamera()
            // screen not authorized → camera auto-selected but no video source (MVP: screen mandatory)
            let (sut, _) = self.makeSUT(
                screen: .notDetermined,
                microphone: .notDetermined,
                cameras: [cam],
                defaults: defaults
            )
            await sut.loadDevices()

            // MVP: screen is mandatory; camera-only deferred post-MVP (decision B, issue #61).
            // hasVideoSource requires screen permission + selectedDisplayID != nil.
            #expect(sut.selectedCameraID != nil)
            #expect(!sut.hasVideoSource)
            #expect(!sut.canRecord)
        }
    }

    // MARK: - AC-2(b): Mic available but not selected → disabled

    @Test("Mic available but not selected → canRecord false, reason provided (AC-2b)")
    func micAvailableNotSelected_cannotRecord() async {
        await withScopedDefaults { defaults in
            let display = Self.makeDisplay()
            let mic = Self.makeMic()
            let (sut, _) = self.makeSUT(
                microphone: .authorized,
                displays: [display],
                microphones: [mic],
                defaults: defaults
            )
            await sut.loadDevices()

            // selectedMicID is nil (no auto-select)
            #expect(sut.selectedMicID == nil)
            #expect(sut.isMicAvailableButUnselected)
            #expect(!sut.canRecord)
            #expect(sut.recordDisabledReason != nil)
        }
    }

    @Test("Mic available and selected → canRecord true (AC-2b resolved)")
    func micAvailableAndSelected_canRecord() async {
        await withScopedDefaults { defaults in
            let display = Self.makeDisplay()
            let mic = Self.makeMic(id: "mic-1")
            let (sut, _) = self.makeSUT(
                microphone: .authorized,
                displays: [display],
                microphones: [mic],
                defaults: defaults
            )
            await sut.loadDevices()

            // Manually select mic
            sut.selectedMicID = "mic-1"

            #expect(!sut.isMicAvailableButUnselected)
            #expect(sut.canRecord)
            #expect(sut.recordDisabledReason == nil)
        }
    }

    // MARK: - AC-2(c): Mic unavailable → record without audio

    @Test("Mic unavailable with screen selected → isRecordingWithoutAudio true, canRecord true (AC-2c)")
    func micUnavailable_isRecordingWithoutAudio() async {
        await withScopedDefaults { defaults in
            let display = Self.makeDisplay()
            let (sut, _) = self.makeSUT(microphone: .denied, displays: [display], defaults: defaults)
            await sut.loadDevices()

            #expect(sut.isRecordingWithoutAudio)
            #expect(sut.canRecord)
            #expect(sut.recordDisabledReason == nil)
        }
    }

    // MARK: - AC-2(d): No video permission → empty state

    @Test("No video permissions → showNoPermissionsState true, canRecord false (AC-2d)")
    func noVideoPermissions_emptyState() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(
                screen: .notDetermined,
                camera: .notDetermined,
                microphone: .authorized,
                defaults: defaults
            )

            #expect(sut.showNoPermissionsState)
        }
    }

    @Test("Screen authorized → showNoPermissionsState false")
    func screenAuthorized_noEmptyState() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(screen: .authorized, camera: .notDetermined, defaults: defaults)

            #expect(!sut.showNoPermissionsState)
        }
    }

    @Test("Camera authorized but screen denied → showNoPermissionsState true (MVP: screen mandatory)")
    func cameraAuthorized_screenDenied_emptyState() {
        withScopedDefaults { defaults in
            // MVP: showNoPermissionsState is screen-anchored (decision B, issue #61).
            // Camera-only does not unlock the main config screen.
            let (sut, _) = self.makeSUT(screen: .notDetermined, camera: .authorized, defaults: defaults)

            #expect(sut.showNoPermissionsState)
        }
    }

    // MARK: - #277: in-window screen-grant action available from the no-permissions state

    @Test("Screen denied → in-window grant action available, not only return-to-onboarding (#277)")
    func screenDenied_inWindowGrantActionAvailable() {
        let (sut, perms) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined,
            defaults: InMemoryUserDefaults()
        )

        // The dead-end contract this test guards: screen denied must expose a working
        // in-window grant seam (request + open Settings + awaiting), mirroring
        // OnboardingViewModel.openScreenRecordingSettings() — not just the return-to-onboarding
        // escape hatch that used to be the only action.
        #expect(sut.showNoPermissionsState)
        #expect(!sut.isAwaitingScreen)

        sut.openScreenRecordingSettings()

        #expect(perms.requestScreenRecordingCallCount == 1)
        #expect(perms.openScreenRecordingSettingsCallCount == 1)
        #expect(sut.isAwaitingScreen)
    }

    @Test("checkScreenStatusNow() from the no-permissions state delegates to PermissionsService (#277)")
    func noPermissionsState_checkScreenStatusNow_delegates() {
        let (sut, perms) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined,
            defaults: InMemoryUserDefaults()
        )
        #expect(sut.showNoPermissionsState)

        sut.checkScreenStatusNow()

        #expect(perms.checkScreenStatusNowCallCount == 1)
    }

    @Test("startScreenPolling() from the no-permissions state delegates to PermissionsService (#277)")
    func noPermissionsState_startScreenPolling_delegates() {
        let (sut, perms) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined,
            defaults: InMemoryUserDefaults()
        )
        #expect(sut.showNoPermissionsState)

        let task = sut.startScreenPolling()
        task.cancel()

        #expect(perms.startScreenPollingCallCount == 1)
    }

    @Test("Screen grant while awaiting → showNoPermissionsState resolves false, reaching a recordable state (#277)")
    func noPermissionsState_screenGranted_leavesEmptyState() {
        let (sut, perms) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined,
            defaults: InMemoryUserDefaults()
        )
        #expect(sut.showNoPermissionsState)

        sut.openScreenRecordingSettings()
        // Simulates the OS-level grant that PermissionsService's real polling would observe —
        // exercising the second half of the #277 contract: the in-window action must actually
        // reach a recordable state, not just flip the awaiting flag (L2, no hardware).
        perms.screenStatus = PermissionStatus.authorized

        #expect(!sut.showNoPermissionsState)
    }

    @Test("Leaving the no-permissions state resets isAwaitingScreen (#277)")
    func noPermissionsState_leave_resetsAwaitingScreen() {
        let (sut, _) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined,
            defaults: InMemoryUserDefaults()
        )
        sut.openScreenRecordingSettings()
        #expect(sut.isAwaitingScreen)

        // Regression for the stale-awaiting strand: opening Settings then leaving via the
        // demoted "Вернуться к разрешениям" fallback without granting must not leave a later
        // re-entry into this state showing a stuck spinner (MainViewModel is app-lifetime).
        sut.leaveNoPermissionsState()

        #expect(!sut.isAwaitingScreen)
    }

    // MARK: - Screen denied state

    @Test("Screen not authorized → isScreenDenied true")
    func screenNotAuthorized_isScreenDenied() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(screen: .notDetermined, defaults: defaults)
            #expect(sut.isScreenDenied)
        }
    }

    @Test("Screen authorized → isScreenDenied false")
    func screenAuthorized_notScreenDenied() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(screen: .authorized, defaults: defaults)
            #expect(!sut.isScreenDenied)
        }
    }

    // MARK: - No video source → canRecord false

    @Test("No display selected (screen authorized) → hasVideoSource false, canRecord false")
    func noDisplaySelected_cannotRecord() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(
                screen: .authorized,
                camera: .notDetermined,
                microphone: .notDetermined,
                defaults: defaults
            )
            // selectedDisplayID is nil (no loadDevices called, no displays provided)
            #expect(sut.selectedDisplayID == nil)
            #expect(!sut.hasVideoSource)
            #expect(!sut.canRecord)
        }
    }

    // MARK: - Preview handle nil without camera selection

    @Test("No camera selected → previewHandle is nil initially")
    func noCameraSelected_previewHandleNil() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(defaults: defaults)
            // No loadDevices called — clean initial state
            #expect(sut.previewHandle == nil)
            #expect(sut.selectedCameraID == nil)
        }
    }

    // MARK: - cameraPlaceholderPending

    /// `cameraPlaceholderPending` is `true` for both the connecting state (previewFailed = false)
    /// and the failed state (previewFailed = true), as long as the camera is active and the
    /// handle has not arrived.
    @Test("cameraPlaceholderPending is true while active, handle nil — regardless of previewFailed")
    func cameraPlaceholderPending_trueForBothConnectingAndFailed() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(defaults: defaults)
            let format = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30.0, maxFps: 30.0)
            let device = CameraDevice(uniqueID: "cam-1", formats: [format])
            sut.cameras = [device]
            sut.selectedCameraID = device.uniqueID

            // Baseline: active camera, no handle, not failed → pending
            #expect(sut.cameraPlaceholderPending)

            // Failed state: still pending (handle still nil)
            sut.previewState = .failed
            #expect(sut.cameraPlaceholderPending)
        }
    }

    // MARK: - Preview state bridges (#254)

    @Test("previewState computed bridges map each case to handle/failed/slow correctly")
    func previewState_bridges() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(defaults: defaults)

            // live → handle non-nil, not failed, not slow
            let session = AVCaptureSession()
            sut.previewState = .live(SessionHandle(session: session))
            #expect(sut.previewHandle != nil)
            #expect(sut.previewHandle?.session === session)
            #expect(!sut.previewFailed)
            #expect(!sut.previewIsConnectingSlow)

            // failed → previewFailed true, handle nil, not slow
            sut.previewState = .failed
            #expect(sut.previewFailed)
            #expect(sut.previewHandle == nil)
            #expect(!sut.previewIsConnectingSlow)

            // idle → handle nil, not failed, not slow
            sut.previewState = .idle
            #expect(sut.previewHandle == nil)
            #expect(!sut.previewFailed)
            #expect(!sut.previewIsConnectingSlow)

            // connecting → handle nil, not failed, not slow
            sut.previewState = .connecting
            #expect(sut.previewHandle == nil)
            #expect(!sut.previewFailed)
            #expect(!sut.previewIsConnectingSlow)

            // connectingSlow → previewIsConnectingSlow true, handle nil, not failed
            sut.previewState = .connectingSlow
            #expect(sut.previewIsConnectingSlow)
            #expect(sut.previewHandle == nil)
            #expect(!sut.previewFailed)
        }
    }

    @Test("managePreview(nil) after a failed attempt clears the failure (1:1 with old unconditional reset)")
    func managePreviewNil_afterFailure_clearsFailed() async {
        await withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(defaults: defaults)
            // Simulate a prior terminal failure recorded with no live preview source.
            sut.previewState = .failed

            // Deselecting the camera must clear the sticky failure, mirroring the old
            // unconditional `previewFailed = false` at the top of managePreview.
            await sut.managePreview(for: nil)

            #expect(!sut.previewFailed)
        }
    }

    // MARK: - VoiceOver announcement policy (#256)

    /// Posting policy table: from × to × isContinuity → text / priority / nil.
    /// Covers the anti-spam contract (`→ .connecting` → nil, single `→ .live` announcement).
    @Test("previewAnnouncement posting policy — per-transition text/priority/nil (#256)")
    func previewAnnouncement_policy() {
        // → .connecting : nil (anti-spam — never announce the start)
        #expect(previewAnnouncement(from: .idle, to: .connecting, isContinuity: false) == nil)
        #expect(previewAnnouncement(from: .idle, to: .connecting, isContinuity: true) == nil)

        // → .idle : nil
        #expect(previewAnnouncement(from: .live(Self.makeHandle()), to: .idle, isContinuity: false) == nil)

        // connecting → live : a SINGLE "connected" announcement, normal priority (no pair, since
        // connecting was never spoken).
        let live = previewAnnouncement(from: .connecting, to: .live(Self.makeHandle()), isContinuity: false)
        #expect(live?.text == "Камера подключена")
        #expect(live?.isHighPriority == false)

        // → .connectingSlow : status + recovery guidance, normal priority; device-specific copy.
        let slowBuiltIn = previewAnnouncement(from: .connecting, to: .connectingSlow, isContinuity: false)
        #expect(slowBuiltIn?.isHighPriority == false)
        #expect(slowBuiltIn?.text.contains("больше обычного") == true)
        let slowPhone = previewAnnouncement(from: .connecting, to: .connectingSlow, isContinuity: true)
        #expect(slowPhone?.text.contains("iPhone") == true)
        #expect(slowPhone?.text != slowBuiltIn?.text)

        // → .failed : visible failure label, HIGH priority (interrupts a hanging slow notice).
        let failedBuiltIn = previewAnnouncement(from: .connectingSlow, to: .failed, isContinuity: false)
        #expect(failedBuiltIn?.text == "Не удалось подключить камеру")
        #expect(failedBuiltIn?.isHighPriority == true)
        let failedPhone = previewAnnouncement(from: .connectingSlow, to: .failed, isContinuity: true)
        #expect(failedPhone?.text == "Не удалось подключить iPhone")
        #expect(failedPhone?.isHighPriority == true)
    }

    /// The announcement text equals the visible placeholder label (single source, #256):
    /// `previewAnnouncement` and `CameraPreviewLabel` must agree for `.failed`/`.connectingSlow`.
    @Test("Announcement text matches the visible placeholder label — single source (#256)")
    func previewAnnouncement_matchesVisibleLabel() {
        for isContinuity in [false, true] {
            let failed = previewAnnouncement(from: .connecting, to: .failed, isContinuity: isContinuity)
            #expect(failed?.text == CameraPreviewLabel.text(for: .failed, isContinuity: isContinuity))

            let slow = previewAnnouncement(from: .connecting, to: .connectingSlow, isContinuity: isContinuity)
            #expect(slow?.text == CameraPreviewLabel.text(for: .connectingSlow, isContinuity: isContinuity))
        }
    }

    /// `CameraPreviewLabel` branching: `.live` has no placeholder; `.idle`/`.connecting` share the
    /// connecting copy; device-specific strings differ.
    @Test("CameraPreviewLabel text per state — 1:1 with prior view logic (#256)")
    func cameraPreviewLabel_text() {
        // .live → no placeholder text
        #expect(CameraPreviewLabel.text(for: .live(Self.makeHandle()), isContinuity: false) == nil)

        // .idle and .connecting collapse to the same "connecting" copy
        #expect(
            CameraPreviewLabel.text(for: .idle, isContinuity: false)
                == CameraPreviewLabel.text(for: .connecting, isContinuity: false)
        )
        #expect(CameraPreviewLabel.text(for: .connecting, isContinuity: false) == "Подключение камеры…")
        #expect(CameraPreviewLabel.text(for: .connecting, isContinuity: true) == "Подключение iPhone…")

        // .failed device-specific
        #expect(CameraPreviewLabel.text(for: .failed, isContinuity: false) == "Не удалось подключить камеру")
        #expect(CameraPreviewLabel.text(for: .failed, isContinuity: true) == "Не удалось подключить iPhone")
    }

    // MARK: - Camera disconnect announcement (#256)

    /// Session-live unplug (`hasObservedPresentCamera == true`) → high-priority announcement.
    @Test("disconnect_sessionLive_announces — high-priority notice when camera was seen present (#256)")
    func disconnect_sessionLive_announces() {
        let announcement = cameraDisconnectAnnouncement(name: "Тестовая камера", hasObservedPresentCamera: true)
        #expect(announcement != nil)
        #expect(announcement?.isHighPriority == true)
        #expect(announcement?.text.contains("Тестовая камера") == true)
    }

    /// Launch with a saved-but-absent camera (flag still `false`) → no spurious announcement.
    @Test("initialLoadWithAbsentSavedCamera_doesNotAnnounce — flag false at startup → nil (#256)")
    func initialLoadWithAbsentSavedCamera_doesNotAnnounce() {
        let announcement = cameraDisconnectAnnouncement(name: "Тестовая камера", hasObservedPresentCamera: false)
        #expect(announcement == nil)
    }

    /// `hasObservedPresentCamera` starts `false` and is armed by `loadCamerasAndMicrophones`
    /// only once a present camera is resolved (restore or auto-select).
    @Test("hasObservedPresentCamera armed after a present camera is loaded (#256)")
    func hasObservedPresentCamera_armedAfterPresentLoad() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(cameras: [Self.makeCamera()], defaults: defaults)
            #expect(!sut.hasObservedPresentCamera)
            sut.loadCamerasAndMicrophones()
            #expect(sut.hasObservedPresentCamera)
        }
    }

    /// No camera present at load → flag stays `false` (no spurious disconnect announce later).
    @Test("hasObservedPresentCamera stays false when no camera is present at load (#256)")
    func hasObservedPresentCamera_falseWhenNoCamera() {
        withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(cameras: [], defaults: defaults)
            sut.loadCamerasAndMicrophones()
            #expect(!sut.hasObservedPresentCamera)
        }
    }

    // MARK: - Display label

    @Test("Display with refreshHz 0 → label shows name — resolution (no Hz segment)")
    func displayLabel_builtIn() {
        withScopedDefaults { defaults in
            let display = Display(
                displayID: 1,
                name: "Встроенный дисплей",
                pixelWidth: 2560,
                pixelHeight: 1600,
                refreshHz: 0.0
            )
            let (sut, _) = self.makeSUT(defaults: defaults)

            let label = sut.displayLabel(for: display)

            #expect(label == "Встроенный дисплей — 2560×1600")
        }
    }

    @Test("Display with refreshHz 60 → label shows name — resolution @ 60")
    func displayLabel_externalMonitor() {
        withScopedDefaults { defaults in
            let display = Display(
                displayID: 1,
                name: "Внешний дисплей",
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshHz: 60.0
            )
            let (sut, _) = self.makeSUT(defaults: defaults)

            let label = sut.displayLabel(for: display)

            #expect(label == "Внешний дисплей — 1920×1080 @ 60")
        }
    }

    @Test("Display with refreshHz 59.94 → label rounds Hz to 60")
    func displayLabel_fractionalRefreshHz() {
        withScopedDefaults { defaults in
            let display = Display(
                displayID: 1,
                name: "Внешний дисплей",
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshHz: 59.94
            )
            let (sut, _) = self.makeSUT(defaults: defaults)

            let label = sut.displayLabel(for: display)

            #expect(label == "Внешний дисплей — 1920×1080 @ 60")
        }
    }

    // MARK: - Production preview wiring

    /// Verifies the production default `makeCameraSource` closure always produces a `.preview`-role
    /// source. This guards against accidental reversion — if the default were changed to `.record`,
    /// a data output would be attached during preview and this test would fail.
    ///
    /// The `MainViewModel` is constructed WITHOUT a custom `makeCameraSource` injection so the
    /// production default closure runs, not a test double. No hardware is accessed — constructing
    /// a `CameraSource` actor does not start a capture session.
    @Test("Default makeCameraSource closure produces a .preview-role CameraSource (production wiring)")
    func defaultMakeCameraSource_producesPreviewRole() async {
        await withScopedDefaults { defaults in
            let (sut, _) = self.makeSUT(defaults: defaults)
            let format = CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 30.0, maxFps: 60.0)
            let device = CameraDevice(uniqueID: "test-camera", formats: [format])

            let source = sut.makeCameraSource(device, format, nil, .mvpDefault)

            #expect(await source.role == .preview)
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - MainViewModel — buildChecklist

/// Tests for `buildChecklist(display:)`: verifies that `screenDescription` is built
/// via `DisplayLabelMapper.recordingScreenLabel` — HUD format: `"{W}×{H} @ {Hz} Гц"`, no name.
@Suite("MainViewModel — buildChecklist")
@MainActor
struct MainViewModelBuildChecklistTests {
    private func makeSUT(defaults: InMemoryUserDefaults) -> MainViewModel {
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: defaults)
        }
        return MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) }
        )
    }

    @Test("screenDescription is HUD format — resolution @ hz Гц (no name) when refreshHz is non-zero")
    func screenDescription_withHz() {
        withScopedDefaults { defaults in
            let display = Display(
                displayID: 1,
                name: "Внешний дисплей",
                pixelWidth: 3840,
                pixelHeight: 2160,
                refreshHz: 60.0
            )
            let sut = self.makeSUT(defaults: defaults)

            let checklist = sut.buildChecklist(display: display)

            #expect(checklist.screenDescription == "3840×2160 @ 60 Гц")
        }
    }

    @Test("screenDescription is HUD format — resolution only (no name, no hz) when refreshHz is zero")
    func screenDescription_withoutHz() {
        withScopedDefaults { defaults in
            let display = Display(
                displayID: 1,
                name: "Встроенный дисплей",
                pixelWidth: 2560,
                pixelHeight: 1600,
                refreshHz: 0.0
            )
            let sut = self.makeSUT(defaults: defaults)

            let checklist = sut.buildChecklist(display: display)

            #expect(checklist.screenDescription == "2560×1600")
        }
    }
}

// MARK: - MainViewModel — stale camera id healing (#139)

/// Tests for hot-unplug stale-id healing in `selectFirstCameraIfNeeded` (#139).
///
/// Auto-selected cameras are not persisted, so on reload the resolver returns
/// `.noSavedSelection` → `selectFirstCameraIfNeeded()`. Before the fix it only
/// acted on `nil`; after the fix it also heals a non-nil id that no longer
/// matches any device in `cameras`.
@Suite("MainViewModel — stale camera id healing")
@MainActor
struct MainViewModelStaleCameraIDTests {
    private static func makeCamera(id: String) -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    /// Simulates hot-unplug by setting a stale id directly and calling
    /// `selectFirstCameraIfNeeded` — the cheapest path that tests the healed invariant
    /// without needing a two-phase `loadDevices` with a swapped closure.
    @Test("Stale selectedCameraID not in cameras list → healed to first available camera")
    func staleID_healedToFirstCamera() {
        let store = InMemoryUserDefaults()
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: store)
        }
        let cam = Self.makeCamera(id: "cam-new")
        let sut = MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: store) }
        )

        // Directly simulate the post-unplug state: cameras refreshed, id still stale.
        sut.cameras = [cam]
        sut.selectedCameraID = "cam-removed" // stale — not in cameras list

        sut.selectFirstCameraIfNeeded()

        #expect(sut.selectedCameraID == "cam-new")
    }

    @Test("Valid selectedCameraID in cameras list → selectFirstCameraIfNeeded leaves it unchanged")
    func validID_notReplaced() {
        let store = InMemoryUserDefaults()
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: store)
        }
        let cam1 = Self.makeCamera(id: "cam-1")
        let cam2 = Self.makeCamera(id: "cam-2")
        let sut = MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam1, cam2] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: store) }
        )

        sut.cameras = [cam1, cam2]
        sut.selectedCameraID = "cam-2" // valid — present in cameras

        sut.selectFirstCameraIfNeeded()

        // Must NOT overwrite to cam-1 (first in list).
        #expect(sut.selectedCameraID == "cam-2")
    }

    @Test("Nil selectedCameraID → selectFirstCameraIfNeeded selects first camera")
    func nilID_selectsFirst() {
        let store = InMemoryUserDefaults()
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: store)
        }
        let cam = Self.makeCamera(id: "cam-only")
        let sut = MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: store) }
        )

        sut.cameras = [cam]
        sut.selectedCameraID = nil

        sut.selectFirstCameraIfNeeded()

        #expect(sut.selectedCameraID == "cam-only")
    }
}
