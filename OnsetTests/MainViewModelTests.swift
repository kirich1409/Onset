import CoreGraphics
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
    /// Passes an in-memory `DeviceSelectionStore` backed by `InMemoryUserDefaults` so
    /// no `.plist` files are written to `~/Library/Preferences/` during tests.
    /// Use `withScopedDefaults` at the call site and pass the vended instance here.
    private func makeSUT(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .authorized,
        microphone: PermissionStatus = .authorized,
        displays: [Display] = [],
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = [],
        defaults: InMemoryUserDefaults? = nil
    )
    -> (sut: MainViewModel, perms: FakePermissionsService) {
        let perms = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let coordinator = RecordingCoordinator()
        let store: InMemoryUserDefaults = if let provided = defaults {
            provided
        } else {
            // swiftlint:disable:next force_unwrapping
            InMemoryUserDefaults(suiteName: nil)!
        }
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
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

    // MARK: - AC-1: Auto-select when exactly one display

    @Test("One display → selectedDisplayID auto-set after loadDevices (AC-1)")
    func singleDisplay_autoSelected() async {
        let display = Self.makeDisplay()
        let (sut, _) = self.makeSUT(displays: [display])

        #expect(sut.selectedDisplayID == nil)

        await sut.loadDevices()

        #expect(sut.selectedDisplayID == display.displayID)
    }

    @Test("Two displays → selectedDisplayID stays nil (no auto-select)")
    func twoDisplays_noAutoSelect() async {
        let displays = [Self.makeDisplay(id: 1), Self.makeDisplay(id: 2)]
        let (sut, _) = self.makeSUT(displays: displays)

        await sut.loadDevices()

        #expect(sut.selectedDisplayID == nil)
    }

    // MARK: - Camera auto-select on load

    @Test("Camera available → first camera auto-selected after loadDevices")
    func cameraAvailable_firstAutoSelected() async {
        let cam = Self.makeCamera(id: "cam-abc")
        let (sut, _) = self.makeSUT(cameras: [cam])

        await sut.loadDevices()

        #expect(sut.selectedCameraID == "cam-abc")
    }

    @Test("No cameras → selectedCameraID stays nil")
    func noCameras_noAutoSelect() async {
        let (sut, _) = self.makeSUT(cameras: [])

        await sut.loadDevices()

        #expect(sut.selectedCameraID == nil)
    }

    // MARK: - Mic: NO auto-select

    @Test("Microphone available → selectedMicID NOT auto-selected (spec: no mic auto-select)")
    func micAvailable_noAutoSelect() async {
        let mic = Self.makeMic(id: "mic-xyz")
        let (sut, _) = self.makeSUT(microphones: [mic])

        await sut.loadDevices()

        #expect(sut.selectedMicID == nil)
    }

    // MARK: - AC-2(a): Has video source → canRecord true

    @Test("Screen authorized + display selected → canRecord true (AC-2a)")
    func screenAndDisplaySelected_canRecord() async {
        let display = Self.makeDisplay()
        let (sut, _) = self.makeSUT(microphone: .notDetermined, displays: [display])
        await sut.loadDevices()
        // screen authorized, selectedDisplayID auto-set (1 display), no mic

        #expect(sut.selectedDisplayID != nil)
        #expect(sut.hasVideoSource)
        #expect(sut.canRecord) // no mic available, so AC-2c applies — can record
    }

    @Test("Camera selected, screen denied — hasVideoSource false (MVP: screen mandatory)")
    func cameraOnly_noVideoSource() async {
        let cam = Self.makeCamera()
        // screen not authorized → camera auto-selected but no video source (MVP: screen mandatory)
        let (sut, _) = self.makeSUT(screen: .notDetermined, microphone: .notDetermined, cameras: [cam])
        await sut.loadDevices()

        // MVP: screen is mandatory; camera-only deferred post-MVP (decision B, issue #61).
        // hasVideoSource requires screen permission + selectedDisplayID != nil.
        #expect(sut.selectedCameraID != nil)
        #expect(!sut.hasVideoSource)
        #expect(!sut.canRecord)
    }

    // MARK: - AC-2(b): Mic available but not selected → disabled

    @Test("Mic available but not selected → canRecord false, reason provided (AC-2b)")
    func micAvailableNotSelected_cannotRecord() async {
        let display = Self.makeDisplay()
        let mic = Self.makeMic()
        let (sut, _) = self.makeSUT(microphone: .authorized, displays: [display], microphones: [mic])
        await sut.loadDevices()

        // selectedMicID is nil (no auto-select)
        #expect(sut.selectedMicID == nil)
        #expect(sut.isMicAvailableButUnselected)
        #expect(!sut.canRecord)
        #expect(sut.recordDisabledReason != nil)
    }

    @Test("Mic available and selected → canRecord true (AC-2b resolved)")
    func micAvailableAndSelected_canRecord() async {
        let display = Self.makeDisplay()
        let mic = Self.makeMic(id: "mic-1")
        let (sut, _) = self.makeSUT(microphone: .authorized, displays: [display], microphones: [mic])
        await sut.loadDevices()

        // Manually select mic
        sut.selectedMicID = "mic-1"

        #expect(!sut.isMicAvailableButUnselected)
        #expect(sut.canRecord)
        #expect(sut.recordDisabledReason == nil)
    }

    // MARK: - AC-2(c): Mic unavailable → record without audio

    @Test("Mic unavailable with screen selected → isRecordingWithoutAudio true, canRecord true (AC-2c)")
    func micUnavailable_isRecordingWithoutAudio() async {
        let display = Self.makeDisplay()
        let (sut, _) = self.makeSUT(microphone: .denied, displays: [display])
        await sut.loadDevices()

        #expect(sut.isRecordingWithoutAudio)
        #expect(sut.canRecord)
        #expect(sut.recordDisabledReason == nil)
    }

    // MARK: - AC-2(d): No video permission → empty state

    @Test("No video permissions → showNoPermissionsState true, canRecord false (AC-2d)")
    func noVideoPermissions_emptyState() {
        let (sut, _) = self.makeSUT(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .authorized
        )

        #expect(sut.showNoPermissionsState)
    }

    @Test("Screen authorized → showNoPermissionsState false")
    func screenAuthorized_noEmptyState() {
        let (sut, _) = self.makeSUT(screen: .authorized, camera: .notDetermined)

        #expect(!sut.showNoPermissionsState)
    }

    @Test("Camera authorized but screen denied → showNoPermissionsState true (MVP: screen mandatory)")
    func cameraAuthorized_screenDenied_emptyState() {
        // MVP: showNoPermissionsState is screen-anchored (decision B, issue #61).
        // Camera-only does not unlock the main config screen.
        let (sut, _) = self.makeSUT(screen: .notDetermined, camera: .authorized)

        #expect(sut.showNoPermissionsState)
    }

    // MARK: - Screen denied state

    @Test("Screen not authorized → isScreenDenied true")
    func screenNotAuthorized_isScreenDenied() {
        let (sut, _) = self.makeSUT(screen: .notDetermined)
        #expect(sut.isScreenDenied)
    }

    @Test("Screen authorized → isScreenDenied false")
    func screenAuthorized_notScreenDenied() {
        let (sut, _) = self.makeSUT(screen: .authorized)
        #expect(!sut.isScreenDenied)
    }

    // MARK: - No video source → canRecord false

    @Test("No display selected (screen authorized) → hasVideoSource false, canRecord false")
    func noDisplaySelected_cannotRecord() {
        let (sut, _) = self.makeSUT(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        // selectedDisplayID is nil (no loadDevices called, no displays provided)
        #expect(sut.selectedDisplayID == nil)
        #expect(!sut.hasVideoSource)
        #expect(!sut.canRecord)
    }

    // MARK: - Preview handle nil without camera selection

    @Test("No camera selected → previewHandle is nil initially")
    func noCameraSelected_previewHandleNil() {
        let (sut, _) = self.makeSUT()
        // No loadDevices called — clean initial state
        #expect(sut.previewHandle == nil)
        #expect(sut.selectedCameraID == nil)
    }

    // MARK: - Display label

    @Test("Display with refreshHz 0 → label shows name — resolution (no Hz segment)")
    func displayLabel_builtIn() {
        let display = Display(
            displayID: 1,
            name: "Встроенный дисплей",
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshHz: 0.0
        )
        let (sut, _) = self.makeSUT()

        let label = sut.displayLabel(for: display)

        #expect(label == "Встроенный дисплей — 2560×1600")
    }

    @Test("Display with refreshHz 60 → label shows name — resolution @ 60")
    func displayLabel_externalMonitor() {
        let display = Display(
            displayID: 1,
            name: "Внешний дисплей",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 60.0
        )
        let (sut, _) = self.makeSUT()

        let label = sut.displayLabel(for: display)

        #expect(label == "Внешний дисплей — 1920×1080 @ 60")
    }

    @Test("Display with refreshHz 59.94 → label rounds Hz to 60")
    func displayLabel_fractionalRefreshHz() {
        let display = Display(
            displayID: 1,
            name: "Внешний дисплей",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 59.94
        )
        let (sut, _) = self.makeSUT()

        let label = sut.displayLabel(for: display)

        #expect(label == "Внешний дисплей — 1920×1080 @ 60")
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
        let (sut, _) = self.makeSUT()
        let format = CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 30.0, maxFps: 60.0)
        let device = CameraDevice(uniqueID: "test-camera", formats: [format])

        let source = sut.makeCameraSource(device, format, nil, .mvpDefault)

        #expect(await source.role == .preview)
    }
}

// swiftlint:enable type_body_length

// MARK: - MainViewModel — buildChecklist

/// Tests for `buildChecklist(display:)`: verifies that `screenDescription` is built
/// via `DisplayLabelMapper.recordingScreenLabel` — HUD format: `"{W}×{H} @ {Hz} Гц"`, no name.
@Suite("MainViewModel — buildChecklist")
@MainActor
struct MainViewModelBuildChecklistTests {
    private func makeSUT() -> MainViewModel {
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator()
        // swiftlint:disable:next force_unwrapping
        let store = InMemoryUserDefaults(suiteName: nil)!
        return MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
        )
    }

    @Test("screenDescription is HUD format — resolution @ hz Гц (no name) when refreshHz is non-zero")
    func screenDescription_withHz() {
        let display = Display(
            displayID: 1,
            name: "Внешний дисплей",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )
        let sut = self.makeSUT()

        let checklist = sut.buildChecklist(display: display)

        #expect(checklist.screenDescription == "3840×2160 @ 60 Гц")
    }

    @Test("screenDescription is HUD format — resolution only (no name, no hz) when refreshHz is zero")
    func screenDescription_withoutHz() {
        let display = Display(
            displayID: 1,
            name: "Встроенный дисплей",
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshHz: 0.0
        )
        let sut = self.makeSUT()

        let checklist = sut.buildChecklist(display: display)

        #expect(checklist.screenDescription == "2560×1600")
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
    func staleID_healedToFirstCamera() throws {
        let store = try #require(InMemoryUserDefaults(suiteName: nil))
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator()
        let cam = Self.makeCamera(id: "cam-new")
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
        )

        // Directly simulate the post-unplug state: cameras refreshed, id still stale.
        sut.cameras = [cam]
        sut.selectedCameraID = "cam-removed" // stale — not in cameras list

        sut.selectFirstCameraIfNeeded()

        #expect(sut.selectedCameraID == "cam-new")
    }

    @Test("Valid selectedCameraID in cameras list → selectFirstCameraIfNeeded leaves it unchanged")
    func validID_notReplaced() throws {
        let store = try #require(InMemoryUserDefaults(suiteName: nil))
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator()
        let cam1 = Self.makeCamera(id: "cam-1")
        let cam2 = Self.makeCamera(id: "cam-2")
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam1, cam2] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
        )

        sut.cameras = [cam1, cam2]
        sut.selectedCameraID = "cam-2" // valid — present in cameras

        sut.selectFirstCameraIfNeeded()

        // Must NOT overwrite to cam-1 (first in list).
        #expect(sut.selectedCameraID == "cam-2")
    }

    @Test("Nil selectedCameraID → selectFirstCameraIfNeeded selects first camera")
    func nilID_selectsFirst() throws {
        let store = try #require(InMemoryUserDefaults(suiteName: nil))
        let perms = FakePermissionsService()
        let coordinator = RecordingCoordinator()
        let cam = Self.makeCamera(id: "cam-only")
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in [cam] },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
        )

        sut.cameras = [cam]
        sut.selectedCameraID = nil

        sut.selectFirstCameraIfNeeded()

        #expect(sut.selectedCameraID == "cam-only")
    }
}

// MARK: - MainViewModel — clamshell / unavailable camera placeholder (#206)

/// Tests for `shouldShowCameraUnavailablePlaceholder`, the pure-logic predicate that drives
/// the clamshell placeholder in the camera preview slot.
///
/// `DeviceDiscovery.cameras()` filters `isSuspended == true` devices, so in clamshell mode
/// (lid closed, built-in camera suspended) `cameras` is empty and `isCameraActive` is `false`.
/// This predicate distinguishes the "toggle on, no camera" state from "denied" (which owns
/// `CameraDeniedRow`) and "toggle off" (which hides the section).
@Suite("MainViewModel — camera unavailable placeholder")
@MainActor
struct MainViewModelCameraUnavailableTests {
    private static func makeCamera(id: String) -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    private func makeSUT(
        cameraStatus: PermissionStatus = .authorized,
        cameras: [CameraDevice] = []
    ) throws
    -> MainViewModel {
        let store = try #require(InMemoryUserDefaults(suiteName: nil))
        let perms = FakePermissionsService(
            screen: .authorized,
            camera: cameraStatus,
            microphone: .authorized
        )
        let coordinator = RecordingCoordinator()
        return MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: store) }
        )
    }

    @Test("Toggle on, no cameras → shouldShowCameraUnavailablePlaceholder is true")
    func toggleOn_noCameras_showsPlaceholder() throws {
        let sut = try makeSUT(cameras: [])
        sut.cameras = []
        sut.selectedCameraID = nil
        sut.cameraEnabled = true

        #expect(sut.shouldShowCameraUnavailablePlaceholder == true)
    }

    @Test("Toggle on, camera available → shouldShowCameraUnavailablePlaceholder is false")
    func toggleOn_cameraAvailable_noPlaceholder() throws {
        let cam = Self.makeCamera(id: "cam-1")
        let sut = try makeSUT(cameras: [cam])
        sut.cameras = [cam]
        sut.selectedCameraID = cam.uniqueID
        sut.cameraEnabled = true

        #expect(sut.isCameraActive == true)
        #expect(sut.shouldShowCameraUnavailablePlaceholder == false)
    }

    @Test("Toggle off → shouldShowCameraUnavailablePlaceholder is false")
    func toggleOff_noPlaceholder() throws {
        let sut = try makeSUT(cameras: [])
        sut.cameras = []
        sut.selectedCameraID = nil
        sut.cameraEnabled = false

        #expect(sut.shouldShowCameraUnavailablePlaceholder == false)
    }

    @Test("Camera denied → shouldShowCameraUnavailablePlaceholder is false (CameraDeniedRow owns that state)")
    func cameraDenied_noPlaceholder() throws {
        let sut = try makeSUT(cameraStatus: .denied, cameras: [])
        sut.cameras = []
        sut.selectedCameraID = nil
        sut.cameraEnabled = true

        #expect(sut.isCameraDenied == true)
        #expect(sut.shouldShowCameraUnavailablePlaceholder == false)
    }
}
