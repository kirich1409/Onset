import Foundation
@testable import Onset
import os
import Testing

// MARK: - MainViewModelDeviceRefreshTests

// swiftlint:disable no_magic_numbers opening_brace
// Rationale: polling timeouts and synthetic camera-format fixtures — same exemption
// as RecordingCoordinatorTests; file-scoped per OnsetTests conventions. `opening_brace`:
// `makeSUT`'s closure-default param makes SwiftFormat (`wrapMultilineStatementBraces`) wrap the
// function's `-> MainViewModel {` brace onto its own line — SwiftFormat is the formatting source
// of truth, so the SwiftLint rule is suppressed rather than fighting the formatter (mirrors
// MainViewModelPreviewTimeoutTests).

/// Mutable camera-list box shared between the test body (`@MainActor`) and the injected
/// discovery closure. Lock-based per OnsetTests conventions (`FlagBox`) — never raw vars
/// shared across isolation. File-scoped (not nested in the suite) so it does not inherit
/// the suite's `@MainActor` isolation.
private final class DeviceListBox: Sendable {
    private let lock: OSAllocatedUnfairLock<[CameraDevice]>

    init(_ initial: [CameraDevice]) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var value: [CameraDevice] {
        self.lock.withLock { $0 }
    }

    func set(_ cameras: [CameraDevice]) {
        self.lock.withLock { $0 = cameras }
    }
}

/// L2 tests for live device-list refresh (`observeDeviceChanges()`): devices that go
/// away while the main window is open (lid closed → suspended camera filtered from
/// discovery, or hot-unplug) disappear from pickers, and reappear with the saved
/// selection restored.
///
/// Device-change events are injected via the `makeDeviceChangeStream` seam with
/// `AsyncStream.makeStream`; camera discovery reads a lock-protected `DeviceListBox`
/// so the test can swap the "connected" device set between events. Burst behavior is
/// asserted by final state only — the debounce makes reload-count assertions flaky;
/// idempotence of `loadCamerasAndMicrophones()` is the invariant under test.
@Suite("MainViewModel — live device refresh", .timeLimit(.minutes(1)))
@MainActor
struct MainViewModelDeviceRefreshTests {
    // MARK: - Helpers

    private static func makeCamera(id: String) -> CameraDevice {
        CameraDevice(uniqueID: id, formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
    }

    /// Returns a `MainViewModel` whose camera discovery reads `box` and whose
    /// device-change stream is the injected `deviceChanges`.
    private func makeSUT(
        defaults: InMemoryUserDefaults,
        box: DeviceListBox,
        deviceChanges: AsyncStream<DeviceChangeEvent>,
        postAnnouncementSeam: @escaping @Sendable @MainActor (PreviewAnnouncement) -> Void = { _ in }
    )
        -> MainViewModel
    {
        let perms = FakePermissionsService(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
        return MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: RecordingCoordinator {
                UserDefaultsBackendSelectionStore(defaults: defaults)
            },
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in box.value },
            discoverMicrophones: { _ in [] },
            makeDeviceChangeStream: { deviceChanges },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) },
            postAnnouncementSeam: postAnnouncementSeam
        )
    }

    /// MainActor recorder for posted announcements. A `@MainActor` class is implicitly `Sendable`,
    /// so the injected `@Sendable @MainActor` seam can capture it and append synchronously.
    @MainActor
    private final class AnnouncementRecorder {
        private(set) var posted: [(text: String, isHighPriority: Bool)] = []

        func record(_ announcement: PreviewAnnouncement) {
            self.posted.append((announcement.text, announcement.isHighPriority))
        }
    }

    // MARK: - Test 1: event reloads the device list

    /// A device-change event re-runs discovery: a camera that appeared after the initial
    /// load becomes visible in the list without reopening the window.
    @Test("Device-change event reloads the camera list")
    func deviceChangeEvent_reloadsCameraList() async {
        let cam1 = Self.makeCamera(id: "cam-1")
        let cam2 = Self.makeCamera(id: "cam-2")
        let box = DeviceListBox([cam1])
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, box: box, deviceChanges: stream)
            await sut.loadDevices()
            #expect(sut.cameras.count == 1)

            let observeTask = Task { await sut.observeDeviceChanges() }
            box.set([cam1, cam2])
            continuation.yield(.connected)

            let reloaded = await eventuallyMainActor { sut.cameras.count == 2 }
            #expect(reloaded)
            observeTask.cancel()
        }
    }

    // MARK: - Test 2: suspension removes the selected camera → disconnected notice

    /// Lid closes while the window is open: the suspended camera vanishes from discovery,
    /// the selection clears, and the disconnected notice carries the saved name. No
    /// replacement camera is auto-selected (existing `.disconnected` invariant).
    @Test("Suspension event with selected camera gone → disconnected notice, selection nil")
    func suspensionEvent_selectedCameraGone_showsDisconnectedNotice() async {
        let cam = Self.makeCamera(id: "cam-facetime")
        let box = DeviceListBox([cam])
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, box: box, deviceChanges: stream)
            await sut.loadDevices()
            // User selection (triggers didSet persistence) — required for the notice.
            sut.selectedCameraID = cam.uniqueID

            let observeTask = Task { await sut.observeDeviceChanges() }
            // Lid closed: the suspended camera is filtered out of discovery results.
            box.set([])
            continuation.yield(.suspensionChanged)

            let noticeShown = await eventuallyMainActor {
                sut.disconnectedCameraName != nil && sut.selectedCameraID == nil
            }
            #expect(noticeShown)
            observeTask.cancel()
        }
    }

    // MARK: - Test 3: device reappears → selection restored

    /// Lid reopens: the camera re-enters discovery, the saved selection is restored,
    /// and the disconnected notice clears — the full suspend/resume round trip.
    @Test("Device reappears after suspension → selection restored, notice cleared")
    func deviceReappears_selectionRestored() async {
        let cam = Self.makeCamera(id: "cam-facetime")
        let box = DeviceListBox([cam])
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, box: box, deviceChanges: stream)
            await sut.loadDevices()
            sut.selectedCameraID = cam.uniqueID

            let observeTask = Task { await sut.observeDeviceChanges() }

            // Lid closed — camera gone, notice shown.
            box.set([])
            continuation.yield(.suspensionChanged)
            let noticeShown = await eventuallyMainActor { sut.disconnectedCameraName != nil }
            #expect(noticeShown)

            // Lid reopened — camera back, saved selection restored (no-clobber invariant).
            box.set([cam])
            continuation.yield(.suspensionChanged)
            let restored = await eventuallyMainActor {
                sut.selectedCameraID == cam.uniqueID && sut.disconnectedCameraName == nil
            }
            #expect(restored)
            observeTask.cancel()
        }
    }

    // MARK: - Test 4: cameraDisplayNames cache invalidated on reload

    /// After a device-change event causes a reload, `cameraDisplayNames` must contain exactly
    /// the keys present in the new `cameras` list and must not retain keys from devices that
    /// have left the list. This guards the cache-invalidation invariant: a device that goes
    /// away must not keep a stale entry visible to `cameraLabel(for:)` on the next render.
    @Test("Device reload rebuilds cameraDisplayNames — new keys present, old keys absent")
    func deviceReload_cameraDisplayNamesUpdated() async {
        let cam1 = Self.makeCamera(id: "cam-display-1")
        let cam2 = Self.makeCamera(id: "cam-display-2")
        let box = DeviceListBox([cam1])
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, box: box, deviceChanges: stream)
            await sut.loadDevices()
            // After initial load: cam1 present, cam2 absent.
            #expect(sut.cameraDisplayNames.keys.contains(cam1.uniqueID))
            #expect(!sut.cameraDisplayNames.keys.contains(cam2.uniqueID))

            // Swap the device list: cam1 gone, cam2 arrived.
            box.set([cam2])
            let observeTask = Task { await sut.observeDeviceChanges() }
            continuation.yield(.connected)

            let reloaded = await eventuallyMainActor {
                sut.cameraDisplayNames.keys.contains(cam2.uniqueID)
            }
            #expect(reloaded)
            #expect(!sut.cameraDisplayNames.keys.contains(cam1.uniqueID))
            observeTask.cancel()
        }
    }

    // MARK: - Announcement posting integration (#256)

    /// Session-live disconnect: a saved camera present on load 1 (`.restore` arms
    /// `hasObservedPresentCamera`), then gone on the next reload, posts the high-priority
    /// disconnect announcement EXACTLY once. A further reload while still absent must NOT
    /// re-announce (edge-trigger anti-spam).
    ///
    /// Drives `loadCamerasAndMicrophones()` directly (not through the stream + 300ms debounce):
    /// the debounced path makes reload-count assertions flaky (file header), and the direct call
    /// is what `observeDeviceChanges` runs per event. Seeding the store gives a distinctive known
    /// name so the asserted `.disconnected(savedName:)` text is `record.localizedName`, not the ID.
    @Test("Session-live camera disconnect → one high-priority disconnect announcement, no re-spam")
    func sessionLiveDisconnect_postsHighPriorityAnnouncementOnce() async {
        let cam = Self.makeCamera(id: "cam-facetime")
        let box = DeviceListBox([cam])
        let recorder = AnnouncementRecorder()
        let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
        let (stream, _) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            // Seed a saved, present selection → load resolves `.restore` → flag armed and the saved
            // localizedName ("FaceTime HD") is what the later `.disconnected` branch carries.
            UserDefaultsDeviceSelectionStore(defaults: defaults).saveCamera(
                .enabled(DeviceSelectionRecord(uniqueID: cam.uniqueID, localizedName: "FaceTime HD"))
            )
            let sut = self.makeSUT(
                defaults: defaults,
                box: box,
                deviceChanges: stream,
                postAnnouncementSeam: record
            )
            // Load 1: camera present → `.restore` → hasObservedPresentCamera armed.
            await sut.loadDevices()

            // Unplug: camera filtered from discovery → `.disconnected` edge → announce once.
            box.set([])
            sut.loadCamerasAndMicrophones()
            #expect(recorder.posted.count == 1)
            #expect(recorder.posted.first?.text == "Камера «FaceTime HD» отключена")
            #expect(recorder.posted.first?.isHighPriority == true)

            // A second reload while STILL absent must not re-announce (edge-trigger anti-spam).
            sut.loadCamerasAndMicrophones()
            #expect(recorder.posted.count == 1)
        }
    }

    /// Cold launch with a saved-but-absent camera: `hasObservedPresentCamera` is never armed
    /// (the device is gone from load 1), so the `.disconnected` branch must stay silent — no
    /// spurious startup announcement.
    @Test("Initial load with saved-but-absent camera → posts NOTHING")
    func initialLoadAbsentCamera_postsNothing() async {
        let box = DeviceListBox([]) // saved camera is NOT present in discovery
        let recorder = AnnouncementRecorder()
        let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
        let (stream, _) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            // Seed a saved enabled selection whose device is absent → resolves to .disconnected.
            UserDefaultsDeviceSelectionStore(defaults: defaults).saveCamera(
                .enabled(DeviceSelectionRecord(uniqueID: "cam-gone", localizedName: "Saved Camera"))
            )
            let sut = self.makeSUT(
                defaults: defaults,
                box: box,
                deviceChanges: stream,
                postAnnouncementSeam: record
            )
            await sut.loadDevices()

            #expect(sut.disconnectedCameraName != nil) // notice is shown…
            #expect(recorder.posted.isEmpty) // …but no announcement (flag never armed).
        }
    }

    // MARK: - Test 5: finished stream exits the loop

    /// When the stream finishes, `observeDeviceChanges()` returns — no parked task leaks.
    @Test("Finished stream exits the observe loop")
    func streamFinished_observeLoopExits() async {
        let box = DeviceListBox([])
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChangeEvent.self)

        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults, box: box, deviceChanges: stream)
            let observeTask = Task { await sut.observeDeviceChanges() }
            continuation.finish()
            // Reaching past this await proves the loop exited on stream finish —
            // a hang would trip the suite's time limit instead.
            await observeTask.value
        }
    }
}

// MARK: - Polling helper

/// Polls a `@MainActor` condition with a bounded timeout. Mirrors `eventuallyMain` in
/// `RecordingCoordinatorTests.swift` (that helper is file-private); same 8s budget
/// rationale — returns immediately once the condition holds, the wide deadline only
/// covers CI scheduler contention on the failure path.
@MainActor
private func eventuallyMainActor(timeoutMs: Int = 8000, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}

// swiftlint:enable no_magic_numbers opening_brace
