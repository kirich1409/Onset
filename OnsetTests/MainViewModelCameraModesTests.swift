import CoreGraphics
import Foundation
@testable import Onset
import Testing

// swiftformat:disable noForceUnwrapInTests
// Rationale: InMemoryUserDefaults(suiteName:) returns Optional for API compatibility but
// never returns nil for a non-nil suiteName — or nil for a fresh in-memory instance.
// The force-unwrap is safe; `try #require` is not available for non-throwing initialisers.

// MARK: - MainViewModelCameraModesTests

/// L2 tests for the `MainViewModel` camera-mode seam (#113 Stage A).
///
/// Covers:
/// 1. `availableCameraModes` — derived from the selected camera's formats.
/// 2. `selectCameraMode(_:)` — persists the mode and updates `selectedCameraMode`.
/// 3. Mode reset on camera change — `selectedCameraMode` → nil when `selectedCameraID` changes.
/// 4. Mode survives restore — persisted mode is re-applied on `loadDevices()`.
/// 5. Mode reset is guarded — restore path does not double-persist.
///
/// `@MainActor` is required because `MainViewModel` and `FakePermissionsService`
/// are `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("MainViewModel — camera modes seam")
@MainActor
struct MainViewModelCameraModesTests {
    // MARK: - Helpers

    private func makeSUT(
        cameras: [CameraDevice] = [],
        defaults: InMemoryUserDefaults? = nil
    )
    -> (sut: MainViewModel, store: InMemoryUserDefaults) {
        let perms = FakePermissionsService(
            screen: .authorized,
            camera: .authorized,
            microphone: .notDetermined
        )
        let coordinator = RecordingCoordinator()
        // swiftlint:disable:next force_unwrapping
        let actualDefaults = defaults ?? InMemoryUserDefaults(suiteName: nil)!
        let sut = MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: actualDefaults) }
        )
        return (sut, actualDefaults)
    }

    private static func makeCamera(
        id: String,
        formats: [CameraFormat] = []
    )
    -> CameraDevice {
        CameraDevice(uniqueID: id, formats: formats)
    }

    private static func makeBrioCamera() -> CameraDevice {
        // Brio-like: 4K@30, 1080p@60, 720p@60
        CameraDevice(uniqueID: "brio", formats: [
            CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 1, maxFps: 30),
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60),
            CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 1, maxFps: 60),
        ])
    }

    // MARK: - availableCameraModes

    @Test("availableCameraModes is empty when no camera is selected")
    func availableCameraModes_noCameraSelected_isEmpty() {
        let (sut, _) = self.makeSUT(cameras: [])
        #expect(sut.availableCameraModes.isEmpty)
    }

    @Test("availableCameraModes reflects selected camera's format modes")
    func availableCameraModes_withBrioCamera_returnsThreeModes() async {
        let brio = Self.makeBrioCamera()
        let (sut, _) = self.makeSUT(cameras: [brio])
        await sut.loadDevices()

        // loadDevices auto-selects first camera → brio is selected
        let modes = sut.availableCameraModes
        #expect(modes.count == 3)
        // Sorted by descending pixel count: 4K, 1080p, 720p
        #expect(modes[0].pixelWidth == 3840 && modes[0].pixelHeight == 2160 && modes[0].fps == 30)
        #expect(modes[1].pixelWidth == 1920 && modes[1].pixelHeight == 1080 && modes[1].fps == 60)
        #expect(modes[2].pixelWidth == 1280 && modes[2].pixelHeight == 720 && modes[2].fps == 60)
    }

    @Test("availableCameraModes switches when selectedCameraID changes")
    func availableCameraModes_switchesWithCamera() async {
        let cam1 = Self.makeCamera(id: "cam-1", formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60),
        ])
        let cam2 = Self.makeCamera(id: "cam-2", formats: [
            CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 1, maxFps: 30),
        ])
        let (sut, _) = self.makeSUT(cameras: [cam1, cam2])
        await sut.loadDevices()

        sut.selectedCameraID = "cam-2"
        let modes = sut.availableCameraModes
        #expect(modes.count == 1)
        #expect(modes[0].pixelWidth == 1280)
    }

    // MARK: - selectCameraMode

    @Test("selectCameraMode sets selectedCameraMode")
    func selectCameraMode_setsSelectedCameraMode() async {
        let brio = Self.makeBrioCamera()
        let (sut, _) = self.makeSUT(cameras: [brio])
        await sut.loadDevices()

        let mode = CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30)
        sut.selectCameraMode(mode)

        #expect(sut.selectedCameraMode?.pixelWidth == 3840)
        #expect(sut.selectedCameraMode?.fps == 30)
    }

    @Test("selectCameraMode(nil) resets to Auto")
    func selectCameraMode_nil_resetsToAuto() async {
        let brio = Self.makeBrioCamera()
        let (sut, _) = self.makeSUT(cameras: [brio])
        await sut.loadDevices()

        // Set a mode, then clear it
        sut.selectCameraMode(CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30))
        sut.selectCameraMode(nil)

        #expect(sut.selectedCameraMode == nil)
    }

    @Test("selectCameraMode persists the selection to the store")
    func selectCameraMode_persistsSelection() async {
        let brio = Self.makeBrioCamera()
        // swiftlint:disable:next force_unwrapping
        let defaults = InMemoryUserDefaults(suiteName: nil)!
        let (sut, _) = self.makeSUT(cameras: [brio], defaults: defaults)
        await sut.loadDevices()

        let mode = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60)
        sut.selectCameraMode(mode)

        // Verify persistence by loading from the same store instance.
        let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
        let loaded = store.loadCamera()
        if case let .enabled(_, mode: persistedMode) = loaded {
            #expect(persistedMode?.pixelWidth == 1920)
            #expect(persistedMode?.fps == 60)
        } else {
            Issue.record("Expected .enabled with mode, got \(String(describing: loaded))")
        }
    }

    // MARK: - Mode reset on camera change

    @Test("selectedCameraMode is reset to nil when selectedCameraID changes")
    func selectedCameraID_change_resetsCameraMode() async {
        let cam1 = Self.makeCamera(id: "cam-1", formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60),
        ])
        let cam2 = Self.makeCamera(id: "cam-2", formats: [
            CameraFormat(pixelWidth: 1280, pixelHeight: 720, minFps: 1, maxFps: 30),
        ])
        let (sut, _) = self.makeSUT(cameras: [cam1, cam2])
        await sut.loadDevices()

        // Set a mode on cam-1
        sut.selectCameraMode(CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60))
        #expect(sut.selectedCameraMode != nil)

        // Switch camera — mode must reset
        sut.selectedCameraID = "cam-2"
        #expect(sut.selectedCameraMode == nil)
    }

    // MARK: - Mode survives restore

    @Test("Persisted mode is restored on loadDevices")
    func persistedMode_survivesRestore() async {
        // swiftlint:disable:next force_unwrapping
        let defaults = InMemoryUserDefaults(suiteName: nil)!
        let brio = Self.makeBrioCamera()

        // Pre-populate the store with a saved mode.
        let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
        let record = DeviceSelectionRecord(uniqueID: "brio", localizedName: "Brio")
        let savedMode = CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30)
        store.saveCamera(.enabled(record, mode: savedMode))

        let (sut, _) = self.makeSUT(cameras: [brio], defaults: defaults)
        await sut.loadDevices()

        // Mode must survive restore — selectedCameraMode should match saved value.
        #expect(sut.selectedCameraID == "brio")
        #expect(sut.selectedCameraMode?.pixelWidth == 3840)
        #expect(sut.selectedCameraMode?.pixelHeight == 2160)
        #expect(sut.selectedCameraMode?.fps == 30)
    }

    @Test("Nil mode in persisted selection restores as Auto (nil)")
    func persistedNilMode_restoresAsAuto() async {
        // swiftlint:disable:next force_unwrapping
        let defaults = InMemoryUserDefaults(suiteName: nil)!
        let brio = Self.makeBrioCamera()

        let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
        let record = DeviceSelectionRecord(uniqueID: "brio", localizedName: "Brio")
        store.saveCamera(.enabled(record, mode: nil))

        let (sut, _) = self.makeSUT(cameras: [brio], defaults: defaults)
        await sut.loadDevices()

        #expect(sut.selectedCameraID == "brio")
        #expect(sut.selectedCameraMode == nil)
    }

    // MARK: - selectCameraMode is a no-op during restore

    @Test("selectCameraMode no-ops when isApplyingPersistedSelection is true")
    func selectCameraMode_noOpDuringRestore() async {
        let brio = Self.makeBrioCamera()
        let (sut, _) = self.makeSUT(cameras: [brio])
        await sut.loadDevices()

        // Simulate mid-restore: set guard, call selectCameraMode
        sut.isApplyingPersistedSelection = true
        let mode = CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30)
        sut.selectCameraMode(mode)
        sut.isApplyingPersistedSelection = false

        // Guard must have blocked the write
        #expect(sut.selectedCameraMode == nil)
    }

    // MARK: - Default value

    @Test("selectedCameraMode defaults to nil (Auto) on fresh model")
    func selectedCameraMode_defaultsToNil() {
        let (sut, _) = self.makeSUT()
        #expect(sut.selectedCameraMode == nil)
    }
}
