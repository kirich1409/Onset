import AVFoundation
import Foundation
@testable import Onset
import Testing

// MARK: - MainViewModelPreviewTimeoutTests (#255)

// swiftlint:disable type_body_length opening_brace file_length closure_body_length
// Rationale: covers the full soft-connect watchdog surface (state-gate, attempt-gate,
// identity-gate, late-handle promotion) plus the one concurrent A→B device-switch path
// and the #256 announcement-posting integration; splitting would scatter closely related
// #255/#256 ACs (type_body_length, file_length). `opening_brace`: `makeSUT`'s closure-default
// params make SwiftFormat (`wrapMultilineStatementBraces`) wrap the function brace onto its own
// line — SwiftFormat is the formatting source of truth, so the SwiftLint rule is suppressed for
// this file rather than fighting the formatter. `closure_body_length`: the issue #227
// `withScopedDefaults { defaults in … }` isolation wrapper adds one line to the one test body
// that was already at the 30-line limit — a project-wide test-isolation seam, not local bloat.

/// Deterministic L2 coverage of the #255 soft-connect timeout.
///
/// The watchdog half is ordered via the injected `connectSleep` seam and the build half via the
/// injected `startPreviewSource` seam — no real `Task.sleep`, no hardware `CameraSource.start()`.
/// Most cases drive the internal `runConnectWatchdog` / `buildAndStartPreview` MainActor methods
/// directly; only `staleWatchdog_afterDeviceSwitch_doesNotMutate` exercises the full concurrent
/// `managePreview` task group, as its AC demands the real A→B re-entry path.
@Suite("MainViewModel — preview soft timeout (#255)")
@MainActor
struct MainViewModelPreviewTimeoutTests {
    // MARK: - Gate dispenser

    /// Hands out per-call async gates by call order, so a `connectSleep` double driving two
    /// concurrent watchdogs can release the first (camera A) independently of the second (camera B).
    /// Each `sleep()` call records its entry (`enteredCount`, pollable) and suspends until
    /// `release(callIndex:)` is called for its index. Cancellation-aware: a cancelled task resumes
    /// immediately so cancelling the driving `managePreview` tasks never leaks a parked watchdog.
    private final class GateDispenser: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var releasedIndices: Set<Int> = []
        private var callCount = 0
        private var _enteredCount = 0
        private var _exitedCount = 0

        /// Number of `sleep()` calls that have entered — poll this to order the test.
        var enteredCount: Int {
            self.lock.withLock { self._enteredCount }
        }

        /// Number of `sleep()` calls that have returned. A watchdog's gate guard runs synchronously
        /// after `connectSleep` returns (no `await` between), so `exitedCount >= n` proves the guard ran.
        var exitedCount: Int {
            self.lock.withLock { self._exitedCount }
        }

        /// The sleep seam: claims the next call index, records entry, and suspends until released.
        func sleep() async {
            let index = self.lock.withLock { () -> Int in
                defer {
                    self.callCount += 1
                    self._enteredCount += 1
                }
                return self.callCount
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = self.lock.withLock { () -> Bool in
                        if self.releasedIndices.contains(index) { return true }
                        self.continuations[index] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                self.release(callIndex: index)
            }
            self.lock.withLock { self._exitedCount += 1 }
        }

        /// Releases the gate for `callIndex` (the watchdog's `connectSleep` then returns).
        func release(callIndex: Int) {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                self.releasedIndices.insert(callIndex)
                return self.continuations.removeValue(forKey: callIndex)
            }
            continuation?.resume()
        }
    }

    // MARK: - SUT

    private func makeSUT(
        cameras: [CameraDevice] = [],
        connectSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        startPreviewSource: @escaping @Sendable (CameraSource) async throws -> SessionHandle? = { _ in nil },
        postAnnouncementSeam: @escaping @Sendable @MainActor (PreviewAnnouncement) -> Void = { _ in },
        defaults: InMemoryUserDefaults
    )
        -> (sut: MainViewModel, perms: FakePermissionsService)
    {
        let perms = FakePermissionsService(screen: .authorized, camera: .authorized, microphone: .notDetermined)
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: defaults)
        }
        let sut = MainViewModel(
            permissions: perms,
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: coordinator,
            discoverDisplays: { _ in [] },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in [] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) },
            connectSleep: connectSleep,
            startPreviewSource: startPreviewSource,
            postAnnouncementSeam: postAnnouncementSeam
        )
        return (sut, perms)
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

    private static func makeCamera(id: String = "cam-1", isContinuity: Bool = false) -> CameraDevice {
        CameraDevice(
            uniqueID: id,
            formats: [CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60)],
            isContinuityCamera: isContinuity
        )
    }

    private static func makeHandle() -> SessionHandle {
        SessionHandle(session: AVCaptureSession())
    }

    private static func eventuallyMain(timeoutMs: Int = 4000, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    // MARK: - runConnectWatchdog (state-gate / threshold)

    @Test("connecting + threshold elapsed → connectingSlow")
    func connecting_pastThreshold_becomesConnectingSlow() async {
        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            sut.previewAttempt = 1
            sut.previewState = .connecting
            // connectSleep default returns immediately → threshold "elapsed".
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 1)
            #expect(sut.previewIsConnectingSlow)
        }
    }

    @Test("handle arrived before threshold → watchdog leaves .live untouched")
    func buildFast_noSlow() async {
        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            sut.previewAttempt = 1
            sut.previewState = .live(Self.makeHandle())
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 1)
            #expect(sut.previewHandle != nil)
            #expect(!sut.previewIsConnectingSlow)
        }
    }

    @Test("live before threshold → no slow flip")
    func liveBeforeThreshold_noSlow() async {
        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            sut.previewAttempt = 2
            sut.previewState = .live(Self.makeHandle())
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 2)
            #expect(!sut.previewIsConnectingSlow)
        }
    }

    @Test("failed before threshold → no slow flip")
    func failedBeforeThreshold_noSlow() async {
        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            sut.previewAttempt = 1
            sut.previewState = .failed
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 1)
            #expect(sut.previewFailed)
            #expect(!sut.previewIsConnectingSlow)
        }
    }

    @Test("stale attempt → watchdog does not flip even while connecting")
    func staleAttempt_doesNotFlip() async {
        await withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            sut.previewAttempt = 2
            sut.previewState = .connecting
            // Watchdog from attempt 1 fires against the current attempt 2.
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 1)
            #expect(!sut.previewIsConnectingSlow)
        }
    }

    // MARK: - buildAndStartPreview (late handle / identity gate)

    @Test("connectingSlow + late handle → live (late-handle promotion)")
    func connectingSlow_lateHandle_becomesLive() async {
        await withScopedDefaults { defaults in
            let handle = Self.makeHandle()
            // Hoisted into a typed `let` (not a trailing closure): a bare trailing closure on `makeSUT`
            // forward-scans to `connectSleep` (SE-0286) and mis-binds, leaving `startPreviewSource` at its
            // nil default; the explicit seam type pins the binding to `startPreviewSource`. Also dodges
            // SwiftLint `trailing_closure`, which would otherwise push the call back to the broken form.
            let startSource: @Sendable (CameraSource) async throws -> SessionHandle? = { _ in handle }
            let sut = self.makeSUT(startPreviewSource: startSource, defaults: defaults).sut
            sut.previewAttempt = 1
            sut.previewState = .connectingSlow
            let camera = Self.makeCamera()
            let source = await sut.buildAndStartPreview(for: camera, attempt: 1)
            #expect(source != nil)
            #expect(sut.previewHandle != nil)
        }
    }

    @Test("suspended start(A) resuming after switch to B → does not clobber B (identity+attempt gate)")
    func suspendedStartA_afterSwitchToB_doesNotClobberLive() async {
        await withScopedDefaults { defaults in
            let handleA = Self.makeHandle()
            let handleB = Self.makeHandle()
            let cameraA = Self.makeCamera(id: "cam-A")
            let cameraB = Self.makeCamera(id: "cam-B")

            // A's `startPreviewSource` resumes only after B has been switched in: B's source becomes
            // the in-flight `previewSource`, the attempt advances to 2, and state is `.live(B)`.
            // A's handle must then be rejected by BOTH the identity gate (`previewSource === sourceB`,
            // not `sourceA`) and the attempt gate (1 != 2).
            let box = SeamBox()
            // Hoisted into a typed `let` (not a trailing closure): the explicit seam type pins the
            // closure's return type so inference can't collapse it to `Void`, and `@MainActor` is
            // required because the body synchronously mutates MainActor-isolated SUT state via `box`.
            let startA: @Sendable @MainActor (CameraSource) async throws -> SessionHandle? = { _ in
                box.applySwitch?()
                return handleA
            }
            let sut = self.makeSUT(startPreviewSource: startA, defaults: defaults).sut
            let sourceB = sut.makeCameraSource(cameraB, cameraB.formats[0], nil, .mvpDefault)
            box.applySwitch = {
                sut.previewSource = sourceB
                sut.previewAttempt = 2
                sut.previewState = .live(handleB)
            }
            sut.previewAttempt = 1
            sut.previewState = .connecting

            _ = await sut.buildAndStartPreview(for: cameraA, attempt: 1)

            if case let .live(handle) = sut.previewState {
                #expect(handle.session === handleB.session)
            } else {
                Issue.record("expected .live(B), got \(sut.previewState)")
            }
            #expect(sut.previewSource === sourceB)
        }
    }

    /// MainActor box so the `@Sendable` seam closure can invoke a deferred mutation on the SUT.
    @MainActor
    private final class SeamBox {
        var applySwitch: (() -> Void)?
    }

    // MARK: - connectingSlow predicates

    @Test("connectingSlow keeps cameraPlaceholderPending and isCameraConnecting true")
    func connectingSlow_keepsPlaceholderAndConnecting() async {
        await withScopedDefaults { defaults in
            let camera = Self.makeCamera()
            let sut = self.makeSUT(cameras: [camera], defaults: defaults).sut
            await sut.loadDevices()
            sut.previewState = .connectingSlow
            #expect(sut.isCameraActive)
            #expect(sut.cameraPlaceholderPending)
            #expect(sut.isCameraConnecting)
            #expect(!sut.previewFailed)
        }
    }

    // MARK: - connectTimeout thresholds

    @Test("Continuity threshold longer than built-in/USB")
    func connectTimeout_continuityLongerThanBuiltIn() {
        withScopedDefaults { defaults in
            let sut = self.makeSUT(defaults: defaults).sut
            #expect(sut.connectTimeout(isContinuity: true) > sut.connectTimeout(isContinuity: false))
        }
    }

    // MARK: - Announcement posting integration (#256)

    @Test("connecting → live drive → exactly one 'Камера подключена', normal priority (no connecting announce)")
    func connectingToLive_postsSingleConnectedAnnouncement() async {
        await withScopedDefaults { defaults in
            let recorder = AnnouncementRecorder()
            let handle = Self.makeHandle()
            let startSource: @Sendable (CameraSource) async throws -> SessionHandle? = { _ in handle }
            let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
            let sut = self.makeSUT(startPreviewSource: startSource, postAnnouncementSeam: record, defaults: defaults)
                .sut
            // Mirror managePreview's pre-build state: a real .connecting attempt in flight.
            sut.previewAttempt = 1
            sut.setPreviewState(.connecting)
            let camera = Self.makeCamera()

            _ = await sut.buildAndStartPreview(for: camera, attempt: 1)

            // Anti-spam: .connecting is silent, only the .live transition speaks — exactly one post.
            #expect(recorder.posted.count == 1)
            #expect(recorder.posted.first?.text == "Камера подключена")
            #expect(recorder.posted.first?.isHighPriority == false)
        }
    }

    @Test("connecting → connectingSlow drive → posts the slow text, normal priority")
    func connectingToSlow_postsSlowText() async {
        await withScopedDefaults { defaults in
            let recorder = AnnouncementRecorder()
            let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
            let sut = self.makeSUT(postAnnouncementSeam: record, defaults: defaults).sut
            sut.previewAttempt = 1
            sut.setPreviewState(.connecting)
            // connectSleep default returns immediately → threshold "elapsed", flips to .connectingSlow.
            await sut.runConnectWatchdog(threshold: .seconds(5), attempt: 1)

            let expected = CameraPreviewLabel.text(for: .connectingSlow, isContinuity: false)
            #expect(sut.previewIsConnectingSlow)
            #expect(recorder.posted.map(\.text) == [expected])
            #expect(recorder.posted.last?.isHighPriority == false)
        }
    }

    @Test("transition → failed → posts the failed label, HIGH priority")
    func transitionToFailed_postsFailedHighPriority() {
        withScopedDefaults { defaults in
            let recorder = AnnouncementRecorder()
            let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
            let sut = self.makeSUT(postAnnouncementSeam: record, defaults: defaults).sut
            sut.previewAttempt = 1
            sut.setPreviewState(.connecting)
            sut.setPreviewState(.failed)

            // No active camera selected → isContinuity false → built-in failed copy.
            let expected = CameraPreviewLabel.text(for: .failed, isContinuity: false)
            #expect(recorder.posted.map(\.text) == [expected])
            #expect(recorder.posted.last?.isHighPriority == true)
        }
    }

    @Test("transition → idle / plain connecting → posts NOTHING (anti-spam)")
    func transitionToIdleOrConnecting_postsNothing() {
        withScopedDefaults { defaults in
            let recorder = AnnouncementRecorder()
            let record: @Sendable @MainActor (PreviewAnnouncement) -> Void = { recorder.record($0) }
            let sut = self.makeSUT(postAnnouncementSeam: record, defaults: defaults).sut
            sut.previewAttempt = 1
            sut.setPreviewState(.connecting)
            sut.setPreviewState(.idle)
            sut.setPreviewState(.connecting)

            #expect(recorder.posted.isEmpty)
        }
    }

    // MARK: - Full concurrent managePreview A→B (attempt-gate, not cancellation)

    @Test("stale watchdog A after device switch to B does not mutate B's state (attempt-gate, not cancellation)")
    func staleWatchdog_afterDeviceSwitch_doesNotMutate() async {
        await withScopedDefaults { defaults in
            let cameraA = Self.makeCamera(id: "cam-A")
            let cameraB = Self.makeCamera(id: "cam-B")
            let handle = Self.makeHandle()

            // Two gate dispensers, both keyed by call order (call 0 = A, call 1 = B):
            //  - sleepGates: A's/B's watchdog `connectSleep`.
            //  - buildGates: A's/B's `startPreviewSource` — HELD so A stays in-flight (group + watchdogA
            //    alive, A never cancelled) and B stays `.connecting` (state-gate would PASS for A's
            //    watchdog). This isolates the attempt-gate as the ONLY barrier under test.
            let sleepGates = GateDispenser()
            let buildGates = GateDispenser()
            let sut = self.makeSUT(
                cameras: [cameraA, cameraB],
                connectSleep: { @Sendable _ in await sleepGates.sleep() },
                startPreviewSource: { @Sendable _ in await buildGates.sleep()
                    return handle
                },
                defaults: defaults
            ).sut
            // `makeSUT` only injects `discoverCameras`; `self.cameras` is populated solely by
            // `loadDevices`. Without this, `managePreview` hits the hot-unplug guard
            // (`cameras.first(where:)` → nil) and returns before bumping `previewAttempt`. The
            // auto-selected `selectedCameraID` is inert here — the test drives `managePreview`
            // directly, not via `.task(id:)`.
            await sut.loadDevices()

            // Drive A and B as separate manual tasks so neither is auto-cancelled (mirrors two
            // `.task(id:)` re-entries without SwiftUI cancellation interfering).
            let taskA = Task { @MainActor in await sut.managePreview(for: cameraA.uniqueID) }
            #expect(await Self.eventuallyMain { sut.previewAttempt == 1 && sleepGates.enteredCount == 1 })

            let taskB = Task { @MainActor in await sut.managePreview(for: cameraB.uniqueID) }
            // Discriminate "B started" by attempt (both are `.connecting`); B's build is held so B
            // stays `.connecting`, making the state-gate pass for A's watchdog (negative control).
            #expect(await Self.eventuallyMain { sut.previewAttempt == 2 && sleepGates.enteredCount == 2 })

            // Release ONLY A's stale watchdog — its guard now runs `attempt(1) == previewAttempt(2)`.
            sleepGates.release(callIndex: 0)
            // Confirm A's watchdog guard actually executed (exitedCount >= 1) — without this the
            // negative assertion below would be vacuous.
            #expect(await Self.eventuallyMain { sleepGates.exitedCount >= 1 })

            // ONLY the attempt-gate (1 != 2) blocked the flip: B is NOT slow and stays `.connecting`.
            #expect(!sut.previewIsConnectingSlow)
            if case .connecting = sut.previewState {} else {
                Issue.record("B must stay .connecting, got \(sut.previewState)")
            }

            // Cleanup: release held builds (A's resume hits identity/attempt gates → skipped) and B's
            // watchdog, then cancel the parked tasks.
            buildGates.release(callIndex: 0)
            buildGates.release(callIndex: 1)
            sleepGates.release(callIndex: 1)
            taskA.cancel()
            taskB.cancel()
            _ = await taskA.value
            _ = await taskB.value
        }
    }
}

// swiftlint:enable type_body_length opening_brace file_length closure_body_length
