import CoreGraphics
@testable import Onset
import Testing

// MARK: - MainViewModelCameraToggleTests

/// Tests for the camera toggle feature (#77, #76).
///
/// Covers `cameraEnabled`, `activeCamera`, `isCameraActive`, and their effect on the
/// recording request and `canRecord`. The suite is `@MainActor` because `MainViewModel`
/// and `FakePermissionsService` are `@MainActor`-isolated.
@Suite("MainViewModel — camera toggle")
@MainActor
struct MainViewModelCameraToggleTests {
    // MARK: - Helpers

    private func makeSUT(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .authorized,
        microphone: PermissionStatus = .notDetermined,
        cameras: [CameraDevice] = [],
        displays: [Display] = []
    )
    -> MainViewModel {
        let perms = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let coordinator = RecordingCoordinator()
        return MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in [] }
        )
    }

    private static func makeCamera(id: String = "cam-1") -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    private static func makeDisplay() -> Display {
        Display(displayID: 1, name: "Test Display", pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60)
    }

    // MARK: - Default value

    @Test("cameraEnabled defaults to true")
    func cameraEnabled_defaultIsTrue() {
        let sut = self.makeSUT()

        #expect(sut.cameraEnabled == true)
    }

    // MARK: - Toggle off

    @Test("cameraEnabled false → isCameraActive false, activeCamera nil")
    func cameraDisabled_isCameraActiveIsFalse() async {
        let cam = Self.makeCamera()
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()
        // selectedCameraID is auto-set by loadDevices

        sut.cameraEnabled = false

        #expect(sut.isCameraActive == false)
        #expect(sut.activeCamera == nil)
    }

    @Test("cameraEnabled false → resolveCameraFormat returns nil (camera excluded from request)")
    func cameraDisabled_resolveCameraFormat_returnsNil() async throws {
        let cam = Self.makeCamera()
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()

        sut.cameraEnabled = false

        let format = try sut.resolveCameraFormat()
        #expect(format == nil)
    }

    // MARK: - Toggle on + camera selected

    @Test("cameraEnabled true + camera selected → isCameraActive true, activeCamera non-nil")
    func cameraEnabled_withCamera_isActive() async {
        let cam = Self.makeCamera(id: "cam-abc")
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()

        #expect(sut.isCameraActive == true)
        #expect(sut.activeCamera?.uniqueID == "cam-abc")
    }

    @Test("cameraEnabled true + camera selected → resolveCameraFormat returns non-nil")
    func cameraEnabled_withCamera_resolveCameraFormat_returnsFormat() async throws {
        let cam = Self.makeCamera()
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()

        let format = try sut.resolveCameraFormat()
        #expect(format != nil)
    }

    // MARK: - Toggle on with no cameras

    @Test("cameraEnabled true + cameras empty → isCameraActive false (no crash)")
    func cameraEnabled_noCameras_isNotActive() async {
        let sut = self.makeSUT(cameras: [])
        await sut.loadDevices()
        // cameraEnabled defaults to true but no cameras loaded

        #expect(sut.isCameraActive == false)
        #expect(sut.activeCamera == nil)
    }

    // MARK: - canRecord is camera-independent

    @Test("Toggling cameraEnabled does not affect canRecord when screen + display present")
    func cameraToggle_doesNotAffectCanRecord() async {
        let cam = Self.makeCamera()
        let display = Self.makeDisplay()
        let sut = self.makeSUT(cameras: [cam], displays: [display])
        await sut.loadDevices()

        let canRecordBefore = sut.canRecord

        sut.cameraEnabled = false
        let canRecordAfterDisable = sut.canRecord

        sut.cameraEnabled = true
        let canRecordAfterEnable = sut.canRecord

        #expect(canRecordBefore == canRecordAfterDisable)
        #expect(canRecordAfterDisable == canRecordAfterEnable)
    }

    // MARK: - Auto-select on re-enable

    @Test("Re-enabling cameraEnabled when selectedCameraID is nil auto-selects first camera")
    func reEnableCameraEnabled_autoSelectsFirst() async {
        let cam = Self.makeCamera(id: "cam-first")
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()
        // Disable, then clear selection manually (simulating a state where selection was nil)
        sut.cameraEnabled = false
        sut.selectedCameraID = nil

        sut.cameraEnabled = true

        #expect(sut.selectedCameraID == "cam-first")
        #expect(sut.isCameraActive == true)
    }

    // MARK: - buildChecklist reflects toggle

    @Test("buildChecklist omits cameraDescription when cameraEnabled is false")
    func buildChecklist_cameraDisabled_omitsCameraDesc() async {
        let cam = Self.makeCamera()
        let display = Self.makeDisplay()
        let sut = self.makeSUT(cameras: [cam], displays: [display])
        await sut.loadDevices()
        sut.cameraEnabled = false

        let checklist = sut.buildChecklist(display: display)

        #expect(checklist.cameraDescription == nil)
    }

    @Test("buildChecklist includes cameraDescription when cameraEnabled is true")
    func buildChecklist_cameraEnabled_includesCameraDesc() async {
        let cam = Self.makeCamera()
        let display = Self.makeDisplay()
        let sut = self.makeSUT(cameras: [cam], displays: [display])
        await sut.loadDevices()
        // cameraEnabled defaults to true

        let checklist = sut.buildChecklist(display: display)

        #expect(checklist.cameraDescription != nil)
    }

    // MARK: - Re-enable preserves existing selection

    @Test("Re-enabling cameraEnabled preserves non-first selectedCameraID")
    func reEnableCameraEnabled_preservesExistingSelection() async {
        let cam1 = Self.makeCamera(id: "cam-1")
        let cam2 = Self.makeCamera(id: "cam-2")
        let sut = self.makeSUT(cameras: [cam1, cam2])
        await sut.loadDevices()
        // Override auto-selection to the non-first camera.
        sut.selectedCameraID = "cam-2"

        sut.cameraEnabled = false
        sut.cameraEnabled = true

        // selectFirstCameraIfNeeded must early-return because selectedCameraID is non-nil.
        #expect(sut.selectedCameraID == "cam-2")
        #expect(sut.isCameraActive == true)
    }

    // MARK: - Toggle-off masks but does not clear selection

    @Test("cameraEnabled false masks activeCamera but leaves selectedCameraID unchanged")
    func cameraDisabled_masksActiveCamera_doesNotClearSelectedCameraID() async {
        let cam = Self.makeCamera(id: "cam-1")
        let sut = self.makeSUT(cameras: [cam])
        await sut.loadDevices()
        let selectedBefore = sut.selectedCameraID

        sut.cameraEnabled = false

        // activeCamera is masked to nil, but the stored ID must be intact.
        #expect(sut.activeCamera == nil)
        #expect(sut.selectedCameraID == selectedBefore)
    }

    // MARK: - Stale selectedCameraID with non-empty camera list

    @Test("Stale selectedCameraID not present in cameras list → activeCamera nil, isCameraActive false")
    func staleSelectedCameraID_notInCameraList_isInactive() async {
        let camNew = Self.makeCamera(id: "cam-new")
        let sut = self.makeSUT(cameras: [camNew])
        await sut.loadDevices()
        // Simulate a hot-unplug: the stored id no longer matches any available camera.
        sut.selectedCameraID = "cam-removed"

        #expect(sut.activeCamera == nil)
        #expect(sut.isCameraActive == false)
    }
}
