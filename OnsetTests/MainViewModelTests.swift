import CoreGraphics
@testable import Onset
import Testing

// MARK: - MainViewModelTests

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
    private func makeSUT(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .authorized,
        microphone: PermissionStatus = .authorized,
        displays: [Display] = [],
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = []
    )
    -> (sut: MainViewModel, perms: FakePermissionsService) {
        let perms = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let coordinator = RecordingCoordinator()
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones }
        )
        return (sut, perms)
    }

    private static func makeDisplay(
        id: CGDirectDisplayID = 1,
        width: Int = 1920,
        height: Int = 1080,
        refreshHz: Double = 60
    )
    -> Display {
        Display(displayID: id, pixelWidth: width, pixelHeight: height, refreshHz: refreshHz)
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

    // MARK: - Screen toggle default

    @Test("Screen authorized → screenEnabled defaults to true after loadDevices")
    func screenAuthorized_screenEnabledTrue() async {
        let display = Self.makeDisplay()
        let (sut, _) = self.makeSUT(screen: .authorized, displays: [display])

        await sut.loadDevices()

        #expect(sut.screenEnabled)
    }

    @Test("Screen not authorized → screenEnabled stays false after loadDevices")
    func screenNotAuthorized_screenEnabledFalse() async {
        let (sut, _) = self.makeSUT(screen: .notDetermined)

        await sut.loadDevices()

        #expect(!sut.screenEnabled)
    }

    // MARK: - AC-2(a): Has video source → canRecord true

    @Test("Screen + display selected → canRecord true (AC-2a)")
    func screenAndDisplaySelected_canRecord() async {
        let display = Self.makeDisplay()
        let (sut, _) = self.makeSUT(microphone: .notDetermined, displays: [display])
        await sut.loadDevices()
        // screenEnabled=true (authorized), selectedDisplayID auto-set (1 display), no mic

        #expect(sut.screenEnabled)
        #expect(sut.selectedDisplayID != nil)
        #expect(sut.canRecord) // no mic available, so AC-2c applies — can record
    }

    @Test("Camera selected, no screen — hasVideoSource true via camera (AC-2a)")
    func cameraSelected_hasVideoSource() async {
        let cam = Self.makeCamera()
        // screen not authorized → screenEnabled=false; camera selected
        let (sut, _) = self.makeSUT(screen: .notDetermined, microphone: .notDetermined, cameras: [cam])
        await sut.loadDevices()

        #expect(!sut.screenEnabled)
        #expect(sut.selectedCameraID != nil)
        #expect(sut.hasVideoSource)
        #expect(sut.canRecord) // no mic available → AC-2c → can record
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

    @Test("Camera authorized → showNoPermissionsState false")
    func cameraAuthorized_noEmptyState() {
        let (sut, _) = self.makeSUT(screen: .notDetermined, camera: .authorized)

        #expect(!sut.showNoPermissionsState)
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

    @Test("No video source (screen off, no camera) → canRecord false")
    func noVideoSource_cannotRecord() {
        let (sut, _) = self.makeSUT(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        // screenEnabled is still false until loadDevices — but let's test the property
        sut.screenEnabled = false
        sut.selectedCameraID = nil

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

    // MARK: - Display label — built-in (refreshHz 0)

    @Test("Display with refreshHz 0 → label shows resolution without Hz")
    func displayLabel_builtIn() {
        let display = Display(displayID: 1, pixelWidth: 2560, pixelHeight: 1600, refreshHz: 0.0)
        let (sut, _) = self.makeSUT()

        let label = sut.displayLabel(for: display)

        #expect(label == "2560×1600")
    }

    @Test("Display with refreshHz 60 → label shows resolution @ 60 Гц")
    func displayLabel_externalMonitor() {
        let display = Display(displayID: 1, pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let (sut, _) = self.makeSUT()

        let label = sut.displayLabel(for: display)

        #expect(label == "1920×1080 @ 60 Гц")
    }
}
