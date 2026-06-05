// RecordingCoordinatorTests.swift
// OnsetTests
//
// Swift Testing suite for RecordingCoordinator (#12 Phase 0) — the sole recording-state owner.
//
// L2 — no hardware. A FakeRecordingControlling drives the state stream, drop counters, and a
// synthetic RecordingResult, so the coordinator's lifecycle (start → recording, state subscription,
// elapsed timer, stop → finished → origin, degraded warning, idempotent multi-path stop) is
// verified without a real RecordingSession.
//
// swiftlint:disable no_magic_numbers
// swiftlint:disable trailing_closure
// swiftlint:disable file_length
// swiftlint:disable type_body_length
// Rationale: synthetic fixture dimensions / drop counts are inherent test data (no_magic_numbers);
// the `sessionFactory:` closure reads clearer as a labelled argument than as a trailing closure
// (trailing_closure), matching the existing RecordingSessionTests convention.
// file_length/type_body_length: covers full coordinator lifecycle incl. write-failure paths.

import Foundation
@testable import Onset
import Testing

// MARK: - Fake RecordingControlling

/// A hardware-free `RecordingControlling`: drives `recordingStateStream` and `currentDrops()` on
/// demand and returns a configurable `RecordingResult` from `stop()`.
///
/// `@unchecked Sendable` (mirrors `FakeEncoder` in `RecordingSessionTests`): the mutable state is a
/// stored continuation + plain counters touched only from the test and the coordinator's awaited
/// calls, never concurrently mutated across isolations.
private final class FakeRecordingControlling: RecordingControlling, @unchecked Sendable {
    nonisolated let recordingStateStream: AsyncStream<RecordingState>
    private let stateContinuation: AsyncStream<RecordingState>.Continuation

    nonisolated let sourceRevocationStream: AsyncStream<RecordingRevocation>
    private let revocationContinuation: AsyncStream<RecordingRevocation>.Continuation

    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// When set, `start()` throws this (AC-6 / AC-11 path).
    var startError: (any Error)?

    /// The counters returned by `currentDrops()` while recording.
    var liveDrops = DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0)

    /// The result returned by `stop()`.
    var result: RecordingResult

    init(result: RecordingResult) {
        self.result = result
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: RecordingState.self)
        self.recordingStateStream = stateStream
        self.stateContinuation = stateContinuation
        let (revocationStream, revocationContinuation) = AsyncStream.makeStream(of: RecordingRevocation.self)
        self.sourceRevocationStream = revocationStream
        self.revocationContinuation = revocationContinuation
    }

    func start(permissions: EffectivePermissions) async throws {
        self.startCalled = true
        self.startCount += 1
        if let startError { throw startError }
    }

    func stop() async -> RecordingResult {
        self.stopCalled = true
        self.stopCount += 1
        // The live session finishes both streams on stop; mirror that so the coordinator's
        // subscription loops end deterministically.
        self.stateContinuation.finish()
        self.revocationContinuation.finish()
        return self.result
    }

    func currentDrops() async -> DropCounters {
        self.liveDrops
    }

    /// Test hook: push a state transition into the stream (the coordinator is the sole consumer).
    func emitState(_ state: RecordingState) {
        self.stateContinuation.yield(state)
    }

    /// Test hook: push a revocation event into the stream (the coordinator is the sole consumer).
    func emitRevocation(_ revocation: RecordingRevocation) {
        self.revocationContinuation.yield(revocation)
    }
}

// MARK: - Fixtures

private enum CoordinatorFixtures {
    static func plan() -> ResolvedRecordingPlan {
        ResolvedRecordingPlan(
            displayID: 1,
            screenWidth: 1280,
            screenHeight: 720,
            screenFps: 60,
            cameraPlan: nil
        )
    }

    static func display() -> Display {
        Display(displayID: 1, pixelWidth: 1280, pixelHeight: 720, refreshHz: 60)
    }

    static func permissions() -> EffectivePermissions {
        EffectivePermissions(screenAvailable: true, cameraAvailable: false, microphoneAvailable: false)
    }

    static func request(origin: RecordingOrigin = .main) -> RecordingRequest {
        RecordingRequest(
            plan: self.plan(),
            display: self.display(),
            cameraDevice: nil,
            cameraFormat: nil,
            micDevice: nil,
            permissions: self.permissions(),
            checklist: RecordingChecklist(
                screenDescription: "1280×720 @ 60 Hz",
                cameraDescription: nil,
                microphoneDescription: nil
            ),
            origin: origin
        )
    }

    static func result(degradedWarning: Bool = false, backpressureDrops: Int = 0) -> RecordingResult {
        RecordingResult(
            screen: .completed(url: URL(fileURLWithPath: "/tmp/onset-coordinator-screen.mp4")),
            camera: nil,
            drops: DropCounters(
                encoderBackpressureDrops: backpressureDrops,
                captureDrops: 0,
                cfrNormalizationDrops: 0
            ),
            degradedWarning: degradedWarning
        )
    }

    /// A result whose screen writer ended in `.failed`, simulating a disk-full mid-recording.
    static func failedWriteResult() -> RecordingResult {
        struct FakeWriteError: Error, LocalizedError {
            var errorDescription: String? {
                "The disk is full."
            }
        }
        return RecordingResult(
            screen: .failed(
                url: URL(fileURLWithPath: "/tmp/onset-coordinator-screen.mp4"),
                error: FakeWriteError()
            ),
            camera: nil,
            drops: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            degradedWarning: false
        )
    }

    /// Request with all three checklist rows populated (screen + camera + mic).
    static func fullChecklistRequest() -> RecordingRequest {
        RecordingRequest(
            plan: self.plan(),
            display: self.display(),
            cameraDevice: nil,
            cameraFormat: nil,
            micDevice: nil,
            permissions: self.permissions(),
            checklist: RecordingChecklist(
                screenDescription: "1280×720 @ 60 Hz",
                cameraDescription: "FaceTime HD · 1080p30",
                microphoneDescription: "MacBook Pro — микрофон"
            ),
            origin: .main
        )
    }
}

// MARK: - Thread-safe counter

/// Minimal reference-type counter for use in `@Sendable` closures under Swift 6 strict concurrency.
///
/// Wrapped in a class so the closure captures a reference, avoiding the `var` mutation-across-
/// isolation error. `@unchecked Sendable` mirrors `FakeRecordingControlling`: the counter is only
/// incremented from one logical isolation (the coordinator on @MainActor) in these tests.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }
}

/// Polls a `@MainActor` condition with a bounded timeout (mirrors `eventually` in session tests).
@MainActor
private func eventuallyMain(timeoutMs: Int = 2000, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}

// MARK: - Tests

@Suite("RecordingCoordinator — lifecycle (#12 Phase 0)")
@MainActor
struct RecordingCoordinatorTests {
    @Test("start → phase=.recording, checklist captured, windows choreographed")
    func start_transitionsToRecording() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        var openedRecording = false
        var dismissedMain = false
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: { openedRecording = true },
            dismissMainWindow: { dismissedMain = true },
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        try await coordinator.start(CoordinatorFixtures.fullChecklistRequest())

        #expect(coordinator.phase == .recording)
        #expect(fake.startCalled)
        // All three checklist rows must be captured from the request.
        #expect(coordinator.checklist.screenDescription == "1280×720 @ 60 Hz")
        #expect(coordinator.checklist.cameraDescription == "FaceTime HD · 1080p30")
        #expect(coordinator.checklist.microphoneDescription == "MacBook Pro — микрофон")
        #expect(openedRecording, "recording window must open on start (AC-3)")
        #expect(dismissedMain, "main window must hide on start (AC-3)")

        await coordinator.stop()
    }

    @Test("checklist rows are nil when source absent — nil-gating preserved")
    func start_checklistNilGating() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        // Default request: only screenDescription is non-nil; camera + mic are nil.
        try await coordinator.start(CoordinatorFixtures.request())

        #expect(coordinator.checklist.screenDescription != nil)
        #expect(coordinator.checklist.cameraDescription == nil, "camera absent → nil checklist row")
        #expect(coordinator.checklist.microphoneDescription == nil, "mic absent → nil checklist row")

        await coordinator.stop()
    }

    @Test("state stream is consumed — a .degraded transition updates recordingState")
    func stateStream_updatesRecordingState() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.recordingState == .normal, "starts normal")

        fake.emitState(.degraded)

        let degraded = await eventuallyMain { coordinator.recordingState == .degraded }
        #expect(degraded, "coordinator must re-publish the .degraded transition from the stream")

        await coordinator.stop()
    }

    @Test("elapsed increments while recording")
    func elapsed_increments() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        // elapsed starts at 0; the tick loop derives it from the start Date. After ~1.1s it is ≥ 1.
        let ticked = await eventuallyMain(timeoutMs: 3000) { coordinator.elapsed >= 1 }
        #expect(ticked, "elapsed must increment from the start Date while recording")

        await coordinator.stop()
    }

    @Test("stop → phase returns to origin (.main), lastResult set, no warning")
    func stop_returnsToMainOrigin() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        var revealed: [URL]?
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            revealInFinder: { revealed = $0 }
        )

        try await coordinator.start(CoordinatorFixtures.request(origin: .main))
        await coordinator.stop()

        #expect(fake.stopCalled)
        #expect(coordinator.phase == .main, "main origin → return to .main")
        #expect(coordinator.lastResult != nil)
        #expect(coordinator.lastDegradedWarning == false)
        #expect(coordinator.drops.encoderBackpressureDrops == 0, "drops propagate from result (clean path)")
        #expect(coordinator.lastWriteError == nil, "no write error on clean result")
        #expect(revealed?.count == 1, "finished files must be revealed in Finder")
        #expect(revealed?.first?.lastPathComponent == "onset-coordinator-screen.mp4", "revealed URL matches result")
    }

    @Test("stop → phase returns to .idle when started from the menu bar")
    func stop_returnsToIdleOrigin() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request(origin: .menuBar))
        await coordinator.stop()

        #expect(coordinator.phase == .idle, "menu-bar origin → return to .idle")
    }

    @Test("stop computes the degraded warning from the result")
    func stop_computesDegradedWarning() async throws {
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(degradedWarning: true, backpressureDrops: 128)
        )
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == true, "degradedWarning must come from the result")
        #expect(coordinator.drops.encoderBackpressureDrops == 128, "final drops come from the result")
    }

    @Test("stop is idempotent across concurrent paths — teardown runs once")
    func stop_idempotentAcrossPaths() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())

        // Three concurrent stop calls (button / hotkey / menu) — the coordinator's synchronous guard
        // must run its teardown exactly once.
        async let stop1: Void = coordinator.stop()
        async let stop2: Void = coordinator.stop()
        async let stop3: Void = coordinator.stop()
        _ = await (stop1, stop2, stop3)

        #expect(fake.stopCount == 1, "the coordinator must call session.stop() exactly once")
        #expect(coordinator.phase == .main)
    }

    @Test("concurrent start calls result in exactly one session started")
    func start_concurrentCallsStartOneSession() async throws {
        // Thread-safe box for tracking factory invocations across the @Sendable closure boundary.
        // The coordinator's sessionFactory is @Sendable; a plain `var` would be a Swift 6
        // data-race error. An @unchecked Sendable reference box (same pattern as FakeRecordingControlling)
        // satisfies the compiler — the box is only written from @MainActor via the coordinator.
        let factoryCounter = Counter()
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            factoryCounter.increment()
            return fake
        })

        // Two concurrent start() calls (e.g. double-click on Record button). The synchronous
        // isStarting guard must let only one through; session.start() must be called exactly once.
        // factoryCounter verifies the guard fires BEFORE the factory — moving the guard below
        // the factory would create a second session even though only one is started.
        async let start1: Void = coordinator.start(CoordinatorFixtures.request())
        async let start2: Void = coordinator.start(CoordinatorFixtures.request())
        _ = try await (start1, start2)

        // sessionFactory must be called exactly once — guard must fire before the factory.
        #expect(factoryCounter.value == 1)
        #expect(fake.startCount == 1, "concurrent start() calls must start exactly one session")
        #expect(coordinator.phase == .recording)

        await coordinator.stop()
    }

    @Test("elapsed is frozen after stop — the tick loop is cancelled")
    func elapsed_frozenAfterStop() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        // Wait until at least one tick so elapsed > 0 and the loop is confirmed running.
        let ticked = await eventuallyMain(timeoutMs: 3000) { coordinator.elapsed >= 1 }
        #expect(ticked, "prerequisite: elapsed must tick to at least 1 before stopping")

        await coordinator.stop()
        let elapsedAtStop = coordinator.elapsed

        // Give the tick loop one more wake window. If the loop were still running after stop
        // elapsed would increase; it must stay frozen at the value captured at stop time.
        let stillIncrementing = await eventuallyMain(timeoutMs: 1500) { coordinator.elapsed > elapsedAtStop }
        #expect(!stillIncrementing, "elapsed must NOT increment after stop — tick loop must be cancelled")
    }

    @Test("AC-9 degraded-warning lifecycle: set on degraded stop, cleared by acknowledge, absent after clean session")
    func degradedWarning_lifecycle() async throws {
        // Session 1: result carries degradedWarning=true.
        let fake1 = FakeRecordingControlling(
            result: CoordinatorFixtures.result(degradedWarning: true, backpressureDrops: 64)
        )
        // Session 2 fake is returned on the second factory call (stateful factory box, see Counter pattern).
        let fake2 = FakeRecordingControlling(
            result: CoordinatorFixtures.result(degradedWarning: false)
        )
        // Thread-safe call counter: Counter is @unchecked Sendable (see class declaration above);
        // used here so the @Sendable factory closure can switch between fake1/fake2 without a
        // Swift 6 data-race error on a captured `var`.
        let callCounter = Counter()
        // Single coordinator instance — reused across both sessions to verify the FIX 2 reset.
        // A fresh coordinator2 would default false and could never catch stale carry-over.
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            callCounter.increment()
            return callCounter.value == 1 ? fake1 : fake2
        })

        // --- Session 1: degraded stop ---
        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == true, "flag must be true after a degraded stop")

        // Acknowledge: flag must clear.
        coordinator.acknowledgeDegradedWarning()
        #expect(coordinator.lastDegradedWarning == false, "flag must be false after acknowledgeDegradedWarning()")

        // --- Session 2 on the SAME coordinator: clean result must not carry flag forward ---
        // This exercises the FIX 2 reset in start(): lastDegradedWarning must be false at the
        // start of every new session as a structural invariant, not just because fake2 is clean.
        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        // The flag must be false — same coordinator, so FIX 2 reset in start() is exercised.
        #expect(coordinator.lastDegradedWarning == false, "no stale degraded flag on same-instance second session")
    }

    @Test("stop with write-failed result sets lastWriteError; acknowledge clears it")
    func stop_writeFailure_setsError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.failedWriteResult())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastWriteError != nil, "lastWriteError must be set when a writer finishes .failed")

        coordinator.acknowledgeWriteError()
        #expect(coordinator.lastWriteError == nil, "lastWriteError must clear after acknowledgeWriteError()")
    }

    @Test("stop with clean result leaves lastWriteError nil")
    func stop_cleanResult_noWriteError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastWriteError == nil, "lastWriteError must be nil when all writers succeed")
    }

    @Test("start resets lastWriteError from previous session")
    func start_resetsWriteError() async throws {
        let fake1 = FakeRecordingControlling(result: CoordinatorFixtures.failedWriteResult())
        let fake2 = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let callCounter2 = Counter()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            callCounter2.increment()
            return callCounter2.value == 1 ? fake1 : fake2
        })

        // Session 1: ends with a write error.
        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()
        #expect(coordinator.lastWriteError != nil, "prerequisite: write error set after failed session")

        // Session 2: start() must reset lastWriteError before the new session runs.
        try await coordinator.start(CoordinatorFixtures.request())
        // lastWriteError must be nil immediately after start() (reset in the adopt block).
        #expect(coordinator.lastWriteError == nil, "start() must reset lastWriteError so stale error does not linger")

        await coordinator.stop()
    }

    @Test("start failure rethrows and leaves phase unchanged")
    func start_failureRethrows() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.startError = RecordingError.noVideoSource
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.enterMain() // begin in .main

        var threw = false
        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch let error as RecordingError {
            if case .noVideoSource = error { threw = true }
        }

        #expect(threw, "start() must rethrow the RecordingError for the UI to surface (AC-6/AC-11)")
        #expect(coordinator.phase == .main, "phase must be unchanged after a failed start")
    }

    // MARK: - menuBarRecordIntent seam (#38)

    @Test("menuBarRecordIntent seam — installed closure is invoked")
    func menuBarRecordIntent_installedClosureRuns() {
        // Verifies that the coordinator stores and dispatches the intent closure exactly as set.
        // This is the seam wiring test: MainView installs the closure; this proves it fires.
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            FakeRecordingControlling(result: CoordinatorFixtures.result())
        })

        var ran = false
        coordinator.menuBarRecordIntent = { ran = true }
        coordinator.menuBarRecordIntent?()

        #expect(ran, "intent closure must be invoked when menuBarRecordIntent?() is called")
    }

    @Test("menuBarRecordIntent seam — nil intent is a no-op (menu bar fallback path)")
    func menuBarRecordIntent_nilIsNoOp() {
        // When no main window is mounted, intent is nil and the menu bar falls back to
        // openWindow. This test proves the coordinator does not crash on nil intent.
        // The SwiftUI Button else-branch (openWindow) has no unit-test seam — L5 only.
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            FakeRecordingControlling(result: CoordinatorFixtures.result())
        })

        // intent is nil by default; optional-call must be a no-op without crashing.
        coordinator.menuBarRecordIntent?()
        #expect(coordinator.menuBarRecordIntent == nil)
    }
}

// MARK: - Revocation stream (#39 / AC-12 UI seam) coordinator tests

@Suite("RecordingCoordinator — source liveness (#39 / AC-12 UI seam)")
@MainActor
struct RecordingCoordinatorRevocationTests {
    @Test(".sourceRevoked(.screen) → screen liveness false, camera+mic live, phase still .recording")
    func screenRevoked_updatesLiveness() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.sourceLiveness == .allLive, "starts fully live")

        fake.emitRevocation(.sourceRevoked(.screen))

        let settled = await eventuallyMain {
            coordinator.sourceLiveness.screen == false
        }
        #expect(settled, "screen liveness must flip to false after .sourceRevoked(.screen)")
        #expect(coordinator.sourceLiveness.camera, "camera must remain live after screen revoke")
        #expect(coordinator.sourceLiveness.microphone, "microphone must remain live after screen revoke")
        #expect(coordinator.phase == .recording, "phase must remain .recording — recording continues")

        await coordinator.stop()
    }

    @Test(".sourceRevoked(.camera) → camera + mic liveness false, screen live, phase still .recording")
    func cameraRevoked_updatesCameraAndMicLiveness() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.sourceLiveness == .allLive, "starts fully live")

        fake.emitRevocation(.sourceRevoked(.camera))

        let cameraSettled = await eventuallyMain {
            coordinator.sourceLiveness.camera == false
        }
        #expect(cameraSettled, "camera liveness must flip to false after .sourceRevoked(.camera)")
        #expect(!coordinator.sourceLiveness.microphone, "mic liveness must flip to false (mic rides camera)")
        #expect(coordinator.sourceLiveness.screen, "screen must remain live after camera revoke")
        #expect(coordinator.phase == .recording, "phase must remain .recording — screen still records")

        await coordinator.stop()
    }

    @Test(".allVideoSourcesLost → coordinator calls stop(), phase transitions away from .recording")
    func allVideoSourcesLost_stopsSession() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.enterMain() // set origin=.main so we can assert phase==.main after stop
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.phase == .recording)

        fake.emitRevocation(.allVideoSourcesLost)

        let stopped = await eventuallyMain {
            coordinator.phase == .main
        }
        #expect(stopped, "coordinator must stop and transition to .main after .allVideoSourcesLost")
        #expect(coordinator.lastResult != nil, "lastResult must be set after auto-stop")
        #expect(fake.stopCalled, "fake.stop() must have been called")
    }

    @Test("sourceLiveness resets to .allLive on the second recording start")
    func sourceLiveness_resetsToAllLiveOnRestart() async throws {
        // Two fakes so the second start() gets a fresh stream (the first fake's streams are
        // finished by stop(), making it unusable for a second session — same two-fake pattern
        // as degradedWarning_lifecycle).
        let fake1 = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let fake2 = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let callCounter = Counter()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            callCounter.increment()
            return callCounter.value == 1 ? fake1 : fake2
        })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        // --- Session 1: revoke the camera source so sourceLiveness goes stale ---
        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.sourceLiveness == .allLive, "prerequisite: starts fully live")

        fake1.emitRevocation(.sourceRevoked(.camera))
        let cameraRevoked = await eventuallyMain { coordinator.sourceLiveness.camera == false }
        #expect(cameraRevoked, "prerequisite: camera must be marked revoked")

        await coordinator.stop()

        // --- Session 2 on the SAME coordinator: start() must reset sourceLiveness ---
        try await coordinator.start(CoordinatorFixtures.request())
        #expect(
            coordinator.sourceLiveness == .allLive,
            "sourceLiveness must reset to .allLive at the start of every new session (stale revoke must not carry over)"
        )

        await coordinator.stop()
    }
}

// MARK: - Global hotkey toggle (#67 / AC-9 third stop path)

@Suite("RecordingCoordinator — handleHotKey (#67 / AC-9 third stop path)")
@MainActor
struct RecordingCoordinatorHotKeyTests {
    // MARK: - recording in progress → triggers stop

    @Test("recording in progress — handleHotKey triggers stop()")
    func handleHotKey_whileRecording_triggerStop() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        try await coordinator.start(CoordinatorFixtures.request(origin: .main))
        #expect(coordinator.phase == .recording, "prerequisite: must be recording")

        // handleHotKey wraps stop() in a Task. Poll for the phase transition as the existing
        // stop tests do (Task is structured, runs on @MainActor, but may not settle synchronously).
        coordinator.handleHotKey()

        let stopped = await eventuallyMain { coordinator.phase == .main }
        #expect(stopped, "handleHotKey while recording must stop and return to .main origin")
        #expect(fake.stopCalled, "fake.stop() must have been called via handleHotKey")
        #expect(fake.stopCount == 1, "stop must be called exactly once")
    }

    // MARK: - not recording + intent installed → calls intent, NOT openMainWindow

    @Test("not recording + intent installed — handleHotKey calls intent, skips openMainWindow")
    func handleHotKey_notRecording_intentInstalled_callsIntent() {
        let intentCounter = Counter()
        let openWindowCounter = Counter()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in
            FakeRecordingControlling(result: CoordinatorFixtures.result())
        })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: { openWindowCounter.increment() }
        )
        coordinator.menuBarRecordIntent = { intentCounter.increment() }

        coordinator.handleHotKey()

        #expect(intentCounter.value == 1, "handleHotKey must call menuBarRecordIntent when installed")
        #expect(openWindowCounter.value == 0, "handleHotKey must NOT open the main window when intent is installed")
    }

    // MARK: - not recording + no intent → calls openMainWindow, does NOT touch session

    @Test("not recording + no intent — handleHotKey calls openMainWindow, does not start a session")
    func handleHotKey_notRecording_noIntent_opensMainWindow() {
        let openWindowCounter = Counter()
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: { openWindowCounter.increment() }
        )
        // menuBarRecordIntent is nil by default — no install.

        coordinator.handleHotKey()

        #expect(openWindowCounter.value == 1, "handleHotKey with no intent must open the main window")
        #expect(!fake.startCalled, "handleHotKey must NOT start a session when no intent is installed")
    }

    // MARK: - double-tap guard (isStopping memoization)

    @Test("double handleHotKey while recording — stop() runs exactly once")
    func handleHotKey_doubleTap_stopsExactlyOnce() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        try await coordinator.start(CoordinatorFixtures.request(origin: .main))
        #expect(coordinator.phase == .recording, "prerequisite: must be recording")

        // Both handleHotKey() calls enqueue a Task before either runs. Both tasks execute
        // sequentially on @MainActor. The first task's stop() sets isStopping=true synchronously
        // (before its first await), so the second task's guard check in stop() fails —
        // teardown runs exactly once.
        coordinator.handleHotKey()
        coordinator.handleHotKey()

        let stopped = await eventuallyMain { coordinator.phase == .main }
        #expect(stopped, "coordinator must reach .main after double-tap")
        #expect(fake.stopCount == 1, "stop() must be called exactly once despite two handleHotKey() calls")
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable trailing_closure
// swiftlint:enable type_body_length
