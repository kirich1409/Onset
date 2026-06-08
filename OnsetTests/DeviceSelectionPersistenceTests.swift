@testable import Onset
import Testing

// MARK: - DeviceSelectionPersistenceTests

/// L2 tests for device-selection persistence (#109).
///
/// Covers:
/// 1. Happy-path restore: saved selection is present after restart (both camera and mic).
/// 2. Absent-device fallback: saved device is gone → `selectedCameraID`/`selectedMicID` stays nil,
///    disconnected-device notice populated with saved `localizedName`.
/// 3. First-launch default: no saved value → `selectedMicID` stays nil (mic not auto-selected),
///    camera auto-selected to the first available device.
/// 4. Camera disabled → persisted → restored DISABLED (not auto-reverted to FaceTime HD).
/// 5. Camera enabled+selected → persisted → restored enabled with same uniqueID.
/// 6. Camera disabled → absent device on re-enable → `.disconnected` (not auto-select).
/// 7. Disconnected-restore does NOT clobber the saved `.enabled` blob — guard invariant.
/// 8. First launch (no saved camera value) → camera enabled, first camera auto-selected.
///
/// Each test runs fully in-memory via `InMemoryUserDefaults` — no `.plist` file is written.
/// The suite is `@MainActor` because `MainViewModel` is `@MainActor`-isolated.
@Suite("Device selection persistence — #109")
@MainActor
struct DeviceSelectionPersistenceTests {
    // MARK: - Helpers

    private static func makeCamera(id: String) -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    private static func makeMic(id: String) -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: id)
    }

    /// Returns a `MainViewModel` whose store is backed by `defaults`, with the given device lists.
    private func makeSUT(
        defaults: InMemoryUserDefaults,
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = []
    )
    -> MainViewModel {
        let perms = FakePermissionsService(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
        let coordinator = RecordingCoordinator()
        return MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) }
        )
    }

    // MARK: - Test 1: Happy-path restore (P1)

    /// Saved camera and microphone selections are restored after a simulated restart
    /// when both devices are present in the available list.
    @Test("Saved camera and mic selections are restored when devices are present")
    func savedSelections_restored_whenDevicesPresent() async {
        let cam = Self.makeCamera(id: "cam-restore")
        let mic = Self.makeMic(id: "mic-restore")

        await withScopedDefaults { defaults in
            // Arrange — first launch: user selects devices and they are persisted.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam], microphones: [mic])
            await firstLaunch.loadDevices()

            // Simulate user selection (triggers didSet persistence).
            firstLaunch.selectedCameraID = cam.uniqueID
            firstLaunch.selectedMicID = mic.uniqueID

            // Act — second launch with the same store, same device list.
            let secondLaunch = self.makeSUT(defaults: defaults, cameras: [cam], microphones: [mic])
            await secondLaunch.loadDevices()

            // Assert — selections are restored.
            #expect(secondLaunch.selectedCameraID == cam.uniqueID)
            #expect(secondLaunch.selectedMicID == mic.uniqueID)
            #expect(secondLaunch.disconnectedCameraName == nil)
            #expect(secondLaunch.disconnectedMicName == nil)
        }
    }

    // MARK: - Test 2: Absent-device fallback (P1)

    /// When the saved camera is no longer in the available list — even when OTHER cameras
    /// are present — the selection stays nil and the disconnected notice is populated.
    /// This tests the invariant that `.disconnected` never coexists with an auto-selected
    /// fallback camera (FIX 1: contradictory VM state).
    @Test("Saved device absent → selection nil, disconnected notice set (other devices present)")
    func savedSelection_absent_showsDisconnectedNotice() async throws {
        let cam = Self.makeCamera(id: "cam-will-disconnect")
        let otherCam = Self.makeCamera(id: "cam-other")
        let mic = Self.makeMic(id: "mic-will-disconnect")

        try await withScopedDefaults { defaults in
            // Arrange — first launch: user selects devices that later become unavailable.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam], microphones: [mic])
            await firstLaunch.loadDevices()
            firstLaunch.selectedCameraID = cam.uniqueID
            firstLaunch.selectedMicID = mic.uniqueID

            // Act — second launch: saved camera gone, a DIFFERENT camera present (the bug
            // case). Saved mic also gone, empty mic list.
            let secondLaunch = self.makeSUT(
                defaults: defaults,
                cameras: [otherCam],
                microphones: []
            )
            await secondLaunch.loadDevices()

            // Assert — saved camera absent: selection nil AND notice set.
            // Critically, otherCam must NOT be auto-selected (invariant: no .disconnected
            // + auto-fallback coexistence).
            #expect(secondLaunch.selectedCameraID == nil)
            let cameraNotice = try #require(secondLaunch.disconnectedCameraName)
            #expect(!cameraNotice.isEmpty)

            // Saved mic absent (empty list): selection nil AND notice set.
            #expect(secondLaunch.selectedMicID == nil)
            let micNotice = try #require(secondLaunch.disconnectedMicName)
            #expect(!micNotice.isEmpty)
        }
    }

    // MARK: - Test 3: First-launch default (P1)

    /// On first launch (no saved selections), the mic stays unselected, the camera is
    /// enabled and auto-selected, and the record button is blocked (AC-2b).
    @Test("First launch — mic not auto-selected, canRecord false when mic available")
    func firstLaunch_micNotAutoSelected_canRecordFalse() async {
        let cam = Self.makeCamera(id: "cam-default")
        let mic = Self.makeMic(id: "mic-default")
        let display = Display(
            displayID: 1,
            name: "Test Display",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 60
        )

        await withScopedDefaults { defaults in
            let perms = FakePermissionsService(
                screen: .authorized,
                camera: .authorized,
                microphone: .authorized
            )
            let coordinator = RecordingCoordinator()
            let sut = MainViewModel(
                permissions: perms,
                coordinator: coordinator,
                discoverDisplays: { _ in [display] },
                discoverCameras: { _ in [cam] },
                discoverMicrophones: { _ in [mic] },
                makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) }
            )

            // Act — first launch, no prior saved state.
            await sut.loadDevices()

            // Assert — mic not auto-selected, canRecord false (AC-2b), record button blocked.
            #expect(sut.selectedMicID == nil)
            #expect(sut.isMicAvailableButUnselected)
            #expect(!sut.canRecord)
            // Camera IS auto-selected (existing default behavior).
            #expect(sut.selectedCameraID == cam.uniqueID)
        }
    }

    // MARK: - Test 4: Camera disabled → persisted → restored DISABLED (P0)

    /// When the user disables the camera and restarts, the camera must remain DISABLED.
    /// The first available camera must NOT be auto-selected on restore.
    ///
    /// This is the core regression test for the camera-persistence gap: before the fix,
    /// the disabled choice was not persisted and the camera reverted to "FaceTime HD Camera"
    /// on every restart.
    @Test("Camera disabled → persisted → restores as disabled, no auto-select")
    func cameraDisabled_persisted_restoresAsDisabled() async {
        let cam = Self.makeCamera(id: "cam-facetime")

        await withScopedDefaults { defaults in
            // Arrange — first launch: camera is enabled and auto-selected.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await firstLaunch.loadDevices()
            #expect(firstLaunch.cameraEnabled == true)

            // User disables the camera — must be persisted.
            firstLaunch.cameraEnabled = false

            // Act — second launch: same camera still available.
            let secondLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await secondLaunch.loadDevices()

            // Assert — camera must stay disabled; no auto-select to firstCam.
            #expect(secondLaunch.cameraEnabled == false)
            #expect(secondLaunch.selectedCameraID == nil)
            #expect(secondLaunch.activeCamera == nil)
        }
    }

    // MARK: - Test 5: Camera enabled+selected → persisted → restored (P1)

    /// When the user selects a camera and restarts, the camera must restore as enabled
    /// with the same uniqueID. This mirrors the mic happy-path test but for camera.
    @Test("Camera enabled+selected → persisted → restored with same uniqueID")
    func cameraEnabled_selected_persisted_restoresWithSameID() async {
        let cam = Self.makeCamera(id: "cam-mx-brio")

        await withScopedDefaults { defaults in
            // Arrange — first launch: user selects a specific camera.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await firstLaunch.loadDevices()
            firstLaunch.selectedCameraID = cam.uniqueID

            // Act — second launch: same camera still available.
            let secondLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await secondLaunch.loadDevices()

            // Assert — camera restored enabled with the correct ID.
            #expect(secondLaunch.cameraEnabled == true)
            #expect(secondLaunch.selectedCameraID == cam.uniqueID)
        }
    }

    // MARK: - Test 6: Camera enabled+selected, device gone → disconnected (P1)

    /// When the user had a camera selected (enabled) and that camera is absent on the
    /// next launch, the restore path must produce a disconnected notice — not auto-select
    /// a replacement (existing invariant, preserved through format change).
    @Test("Camera enabled+selected, device gone → disconnected notice, no auto-select")
    func cameraEnabled_selectedDeviceGone_showsDisconnectedNotice() async throws {
        let cam = Self.makeCamera(id: "cam-gone")
        let otherCam = Self.makeCamera(id: "cam-other")

        try await withScopedDefaults { defaults in
            // Arrange — first launch: user selects a camera.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await firstLaunch.loadDevices()
            firstLaunch.selectedCameraID = cam.uniqueID

            // Act — second launch: saved camera gone, different camera present.
            let secondLaunch = self.makeSUT(defaults: defaults, cameras: [otherCam])
            await secondLaunch.loadDevices()

            // Assert — enabled but no selection; disconnected notice set; otherCam NOT auto-selected.
            #expect(secondLaunch.cameraEnabled == true)
            #expect(secondLaunch.selectedCameraID == nil)
            let notice = try #require(secondLaunch.disconnectedCameraName)
            #expect(!notice.isEmpty)
        }
    }

    // MARK: - Test 7: Disconnected restore does not clobber the saved blob (P0)

    /// Asserts the no-clobber invariant on the `.disconnected` restore path.
    ///
    /// When a saved `.enabled(record)` camera is restored but the device is absent, the
    /// VM sets `selectedCameraID = nil` while `cameraEnabled = true`. Both `didSet`s must
    /// be suppressed by the `isApplyingPersistedSelection` guard — otherwise
    /// `persistCameraSelection()` would see `(enabled=true, id=nil)` and call `clearCamera()`,
    /// silently deleting the saved choice. This test pins that invariant by:
    /// 1. Persisting `.enabled(record)` via first-launch selection.
    /// 2. Simulating a disconnect (second launch: device absent).
    /// 3. Reading `store.loadCamera()` directly and asserting it equals the blob from step 1.
    /// 4. (Reconnect) Third launch brings the device back → selection restored, notice cleared.
    @Test("Disconnected restore does not clobber the saved camera blob")
    func disconnectedRestore_doesNotClobberSavedCameraSelection() async throws {
        let cam = Self.makeCamera(id: "cam-reconnect")
        let otherCam = Self.makeCamera(id: "cam-bystander")

        try await withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)

            // Arrange — first launch: user selects `cam`; the selection is persisted.
            let firstLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await firstLaunch.loadDevices()
            firstLaunch.selectedCameraID = cam.uniqueID

            // Capture the blob written during the first launch to use as the reference.
            let savedAfterSelection = try #require(store.loadCamera())

            // Act — second launch: `cam` is gone, a bystander is present.
            let secondLaunch = self.makeSUT(defaults: defaults, cameras: [otherCam])
            await secondLaunch.loadDevices()

            // Verify the disconnected notice fired (pre-condition for the clobber to be relevant).
            #expect(secondLaunch.cameraEnabled == true)
            #expect(secondLaunch.selectedCameraID == nil)
            #expect(secondLaunch.disconnectedCameraName != nil)

            // The saved blob must be unchanged — no write-back during disconnected restore.
            #expect(store.loadCamera() == savedAfterSelection)

            // Reconnect — third launch: `cam` is back in the available list.
            let thirdLaunch = self.makeSUT(defaults: defaults, cameras: [cam])
            await thirdLaunch.loadDevices()

            // The preserved blob restores the camera as if the disconnect never happened.
            #expect(thirdLaunch.cameraEnabled == true)
            #expect(thirdLaunch.selectedCameraID == cam.uniqueID)
            #expect(thirdLaunch.disconnectedCameraName == nil)
        }
    }

    // MARK: - Test 8: First launch (no saved camera) → auto-select first (P1)

    /// First launch with no saved camera value: camera must be enabled and the first
    /// available camera auto-selected. This preserves the current default behavior.
    @Test("First launch, no saved camera → camera enabled, first camera auto-selected")
    func firstLaunch_noSavedCamera_enabledAndAutoSelected() async {
        let cam = Self.makeCamera(id: "cam-default")

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, cameras: [cam])
            await sut.loadDevices()

            #expect(sut.cameraEnabled == true)
            #expect(sut.selectedCameraID == cam.uniqueID)
        }
    }
}
