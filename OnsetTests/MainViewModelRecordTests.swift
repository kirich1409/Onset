// MainViewModelRecordTests.swift
// OnsetTests
//
// Swift Testing suite covering `MainViewModel.record()` and its guard / dispatch paths (#36).
//
// L2 — no hardware. The `startSessionOverride` seam on `MainViewModel` replaces
// `coordinator.start(_:)` with a spy closure, so tests verify the dispatch path
// without constructing a real `RecordingSession`.
//
// swiftlint:disable trailing_closure
// Rationale: `startBehavior:` closures read more clearly as labelled arguments
// than trailing closures (mirrors the RecordingCoordinatorTests convention for sessionFactory:).

import CoreGraphics
import Foundation
@testable import Onset
import Testing

// MARK: - MainViewModel — record() dispatch path tests

/// Closure type for the `startSessionOverride` seam — typed to satisfy `@MainActor @Sendable`.
private typealias StartSpy = @MainActor @Sendable (RecordingRequest) async throws -> Void

/// Tests for `MainViewModel.record()` — AC-2 guards, coordinator dispatch, error handling,
/// and `isStartingRecording` re-entrancy guard.
///
/// Suite isolation: each `@Test` in a `@Suite struct` receives a fresh instance — parallel-safe.
@Suite("MainViewModel — record() dispatch")
@MainActor
struct MainViewModelRecordTests {
    // MARK: - Helpers

    private static func makeDisplay(
        id: CGDirectDisplayID = 1,
        width: Int = 1920,
        height: Int = 1080,
        refreshHz: Double = 60
    )
    -> Display {
        Display(displayID: id, name: "Test Display", pixelWidth: width, pixelHeight: height, refreshHz: refreshHz)
    }

    private static func makeMic(id: String = "mic-1") -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: id)
    }

    /// Creates a `MainViewModel` with an injected start-spy closure.
    ///
    /// `startBehavior` replaces `coordinator.start(_:)` so tests exercise the dispatch path
    /// without starting a real `RecordingSession`. `loadDevices()` is called so device lists
    /// and auto-selections match what the live app sees on first appear.
    ///
    /// Both persistence stores are backed by a per-SUT `InMemoryUserDefaults` so tests never
    /// touch the real `~/Library/Preferences/` domain. Without this, the output-directory
    /// tests persisted `/tmp/onset-nonexistent-…` into the shared standard defaults, which
    /// every later `MainViewModel.init` read back — `record()` then failed its directory
    /// validation before reaching `startBehavior`, breaking the valid-path tests and
    /// deadlocking the re-entrancy test (it awaits a signal yielded inside `startBehavior`).
    private func makeSUT(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .notDetermined,
        microphone: PermissionStatus = .notDetermined,
        displays: [Display] = [Self.makeDisplay()],
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = [],
        startBehavior: @escaping StartSpy = { _ in }
    ) async
        -> MainViewModel
    { // swiftlint:disable:this opening_brace
        let perms = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let defaults = InMemoryUserDefaults()
        let sut = MainViewModel(
            permissions: perms,
            coordinator: RecordingCoordinator(),
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) }
        )
        sut.startSessionOverride = startBehavior
        await sut.loadDevices()
        return sut
    }

    // MARK: - AC-2(d): Screen denied → silent early return

    @Test("record() — screen denied → returns early, no coordinator start (AC-2d)")
    func record_screenDenied_returnsEarly() async {
        var startCalled = false
        let sut = await self.makeSUT(
            screen: .notDetermined,
            startBehavior: { _ in startCalled = true }
        )

        await sut.record()

        #expect(!startCalled, "coordinator.start must NOT be called when screen is denied")
        #expect(sut.recordError == nil, "recordError must stay nil — screen-denied is a silent guard")
    }

    // MARK: - AC-2(b): Mic available but unselected → recordError, no start

    @Test("record() — mic available but unselected → recordError set, no coordinator start (AC-2b)")
    func record_micUnselected_errorSet() async {
        var startCalled = false
        let sut = await self.makeSUT(
            microphone: .authorized,
            microphones: [Self.makeMic()],
            startBehavior: { _ in startCalled = true }
        )
        // selectedMicID is nil — no mic auto-select per spec

        await sut.record()

        #expect(!startCalled, "coordinator.start must NOT be called when mic is available but unselected")
        #expect(sut.recordError != nil, "recordError must be set to prompt mic selection (AC-2b)")
    }

    // MARK: - Valid path

    @Test("record() — valid state → coordinator.start invoked exactly once")
    func record_validState_startCalledOnce() async {
        var startCount = 0
        // One display → auto-selected by loadDevices (AC-1); no mic → AC-2c (record without audio).
        let sut = await self.makeSUT(
            startBehavior: { _ in startCount += 1 }
        )

        await sut.record()

        #expect(startCount == 1, "coordinator.start must be called exactly once for a valid record()")
    }

    @Test("record() — coordinator.start throws → recordError set")
    func record_coordinatorThrows_errorSet() async {
        struct FakeError: Error {}
        let sut = await self.makeSUT(
            startBehavior: { _ in throw FakeError() }
        )

        await sut.record()

        #expect(sut.recordError != nil, "recordError must be set when coordinator.start throws")
    }

    // MARK: - Re-entrancy guard

    @Test("record() — isStartingRecording guard prevents concurrent starts")
    func record_reentrancyGuard_onlyOneStart() async {
        var startCount = 0
        // Park the first call inside startBehavior so the second can enter record() and hit the guard.
        let (firstCallEntered, resumeFirst) = AsyncStream<Void>.makeStream()
        let (allowFirst, resumeAllow) = AsyncStream<Void>.makeStream()

        let sut = await self.makeSUT(
            startBehavior: { _ in
                startCount += 1
                resumeFirst.yield(()) // signal: first call is inside start
                for await _ in allowFirst {
                    break
                }
            }
        )

        async let first: Void = sut.record() // parks inside startBehavior
        for await _ in firstCallEntered {
            break
        } // wait until first is inside start
        await sut.record() // hits isStartingRecording guard → no-op
        resumeAllow.yield(()) // release first call
        await first

        #expect(startCount == 1, "only one coordinator.start must be invoked under concurrent record() calls")
    }

    // MARK: - Output-directory validation

    @Test("record() — non-existent output directory → outputDirectoryError set, no coordinator start")
    func record_nonExistentOutputDirectory_errorSet() async {
        var startCalled = false
        let sut = await self.makeSUT(startBehavior: { _ in startCalled = true })
        // Point to a path that cannot exist at test runtime.
        sut.outputDirectoryURL = URL(
            filePath: "/tmp/onset-nonexistent-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        await sut.record()

        #expect(
            !startCalled,
            "coordinator.start must NOT be called when the output directory does not exist"
        )
        #expect(
            sut.outputDirectoryError != nil,
            "outputDirectoryError must be set for a missing output directory"
        )
    }

    @Test("record() — outputDirectoryError reset and re-set on second call after external clear")
    func record_secondCallAfterExternalClear_errorReSet() async {
        let sut = await self.makeSUT()
        let missingURL = URL(
            filePath: "/tmp/onset-nonexistent-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        sut.outputDirectoryURL = missingURL

        // First call: error is set.
        await sut.record()
        #expect(sut.outputDirectoryError != nil, "outputDirectoryError must be set on first call")

        // Simulate alert dismissal resetting the error (what the view's Binding does on OK tap).
        sut.outputDirectoryError = nil

        // Second call with the same missing directory: error must be set again.
        await sut.record()
        #expect(
            sut.outputDirectoryError != nil,
            "outputDirectoryError must be re-set on a second call after external clear"
        )
    }
}

// swiftlint:enable trailing_closure
