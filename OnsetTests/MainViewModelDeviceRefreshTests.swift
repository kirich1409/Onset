import Foundation
@testable import Onset
import os
import Testing

// MARK: - MainViewModelDeviceRefreshTests

// swiftlint:disable no_magic_numbers
// Rationale: polling timeouts and synthetic camera-format fixtures — same exemption
// as RecordingCoordinatorTests; file-scoped per OnsetTests conventions.

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
        deviceChanges: AsyncStream<DeviceChangeEvent>
    )
    -> MainViewModel {
        let perms = FakePermissionsService(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
        return MainViewModel(
            permissions: perms,
            coordinator: RecordingCoordinator(),
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in box.value },
            discoverMicrophones: { _ in [] },
            makeDeviceChangeStream: { deviceChanges },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) }
        )
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

    // MARK: - Test 4: finished stream exits the loop

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
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}
