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
import UserNotifications

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

    nonisolated let captureActiveStream: AsyncStream<Void>
    private let captureActiveContinuation: AsyncStream<Void>.Continuation

    /// Fake session directory — a sentinel path used in coordinator tests. Flagged as a directory to
    /// match real session dirs (`OutputDirectoryNaming.uniqueSessionDirectory` builds them with
    /// `directoryHint: .isDirectory`); without the flag, child-path resolution drops the folder.
    nonisolated let sessionDirectory = URL(filePath: "/tmp/onset-fake-session", directoryHint: .isDirectory)

    /// Fake session-start timestamp — a fixed sentinel for deterministic report-URL derivation.
    nonisolated let sessionStartDate = Date(timeIntervalSince1970: 0)

    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    /// When set, `start()` throws this (AC-6 / AC-11 path).
    var startError: (any Error)?

    /// When `true`, `captureActiveStream` is never yielded — simulates consent denied / timeout.
    var simulateCaptureNeverActivates = false

    /// When `true`, `start()` suspends until `releaseStart()` is called.
    /// Use to simulate a stop() that races the `session.start()` suspension window (Fix 2 scenario b).
    var gateStartEnabled = false
    private let (gateStream, gateContinuation) = AsyncStream.makeStream(of: Void.self)

    /// The health snapshot returned by `currentDrops()` while recording.
    var liveDrops = DropHealthSnapshot(
        counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        sessionEverDegraded: false,
        dominantCause: .notDegraded
    )

    /// The camera rate snapshot returned by `currentRates()`. `nil` → screen-only (no fps detector).
    var liveRates: CameraRateSnapshot?

    /// The monotonic session-relative elapsed seconds returned by `currentSessionElapsedSeconds()`.
    /// Injected as a plain Double so the detector clock is deterministic in L2 — no real wall-clock
    /// wait, and it can be set INDEPENDENTLY of `liveRates.monotonicStampSeconds` to drive the
    /// staleness gate / sustain windows.
    var liveSessionElapsedSeconds: Double = 0

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
        // Relies on the DEFAULT .unbounded buffering: a yield that fires before the coordinator
        // subscribes is retained in the buffer. A .bufferingNewest/Oldest(1) policy would silently
        // drop it and leave the coordinator hanging until the 30 s timeout.
        let (captureActiveStream, captureActiveContinuation) = AsyncStream.makeStream(of: Void.self)
        self.captureActiveStream = captureActiveStream
        self.captureActiveContinuation = captureActiveContinuation
    }

    func start(permissions: EffectivePermissions) async throws {
        self.startCalled = true
        self.startCount += 1
        if let startError { throw startError }
        // When gateStartEnabled, suspend here until releaseStart() is called. This lets a test
        // call coordinator.stop() while start() is blocked — making activationTask still nil at
        // that point — to exercise the Fix 2 (b) race window.
        if self.gateStartEnabled {
            for await _ in self.gateStream {
                break
            }
        }
        // Default behaviour: immediately signal that capture is active, mirroring a live session
        // where consent is pre-granted and the first frame arrives quickly. Tests that want to
        // control the timing call emitCaptureActive() / finishCaptureActiveWithoutActivation()
        // manually and must set simulateCaptureNeverActivates = true to suppress the auto-emit.
        if !self.simulateCaptureNeverActivates {
            self.captureActiveContinuation.yield(())
            self.captureActiveContinuation.finish()
        }
    }

    /// Test hook: unblock a `start()` suspension gated by `gateStartEnabled`.
    func releaseStart() {
        self.gateContinuation.yield(())
        self.gateContinuation.finish()
    }

    func stop() async -> RecordingResult {
        self.stopCalled = true
        self.stopCount += 1
        // The live session finishes all streams on stop; mirror that so the coordinator's
        // subscription loops end deterministically.
        self.stateContinuation.finish()
        self.revocationContinuation.finish()
        self.captureActiveContinuation.finish()
        return self.result
    }

    func currentDrops() async -> DropHealthSnapshot {
        self.liveDrops
    }

    func currentRates() async -> CameraRateSnapshot? {
        self.liveRates
    }

    func currentSessionElapsedSeconds() async -> Double {
        self.liveSessionElapsedSeconds
    }

    /// Test hook: push a state transition into the stream (the coordinator is the sole consumer).
    func emitState(_ state: RecordingState) {
        self.stateContinuation.yield(state)
    }

    /// Test hook: push a revocation event into the stream (the coordinator is the sole consumer).
    func emitRevocation(_ revocation: RecordingRevocation) {
        self.revocationContinuation.yield(revocation)
    }

    /// Test hook: signal capture activation (first real screen frame arrived).
    func emitCaptureActive() {
        self.captureActiveContinuation.yield(())
        self.captureActiveContinuation.finish()
    }

    /// Test hook: finish captureActiveStream WITHOUT yielding — simulates consent denied or
    /// stream terminal-stop arriving before any real frame.
    func finishCaptureActiveWithoutActivation() {
        self.captureActiveContinuation.finish()
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
        Display(displayID: 1, name: "Test Display", pixelWidth: 1280, pixelHeight: 720, refreshHz: 60)
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
                screenDescription: "1280×720 @ 60 Гц",
                cameraDescription: nil,
                microphoneDescription: nil
            ),
            origin: origin,
            config: .mvpDefault
        )
    }

    static func result(backpressureDrops: Int = 0, sessionEverDegraded: Bool = false) -> RecordingResult {
        .completed(
            .screenOnly(.completed(url: URL(fileURLWithPath: "/tmp/onset-coordinator-screen.mp4"))),
            DropHealthSnapshot(
                counters: DropCounters(
                    encoderBackpressureDrops: backpressureDrops,
                    captureDrops: 0,
                    cfrNormalizationDrops: 0
                ),
                sessionEverDegraded: sessionEverDegraded,
                dominantCause: sessionEverDegraded ? .encode : .notDegraded
            )
        )
    }

    /// A result whose screen writer ended in `.failed`, simulating a disk-full mid-recording.
    static func failedWriteResult() -> RecordingResult {
        struct FakeWriteError: Error, LocalizedError {
            var errorDescription: String? {
                "The disk is full."
            }
        }
        return .completed(
            .screenOnly(.failed(
                url: URL(fileURLWithPath: "/tmp/onset-coordinator-screen.mp4"),
                error: FakeWriteError()
            )),
            DropHealthSnapshot(
                counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
                sessionEverDegraded: false,
                dominantCause: .notDegraded
            )
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
                screenDescription: "1280×720 @ 60 Гц",
                cameraDescription: "FaceTime HD · 1080p30",
                microphoneDescription: "MacBook Pro — микрофон"
            ),
            origin: .main,
            config: .mvpDefault
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
/// 8s upper bound: eventuallyMain returns immediately once the condition holds, so this only
/// widens the failure-path budget — the success path is unaffected. Swift Testing runs @Test funcs
/// in parallel; under CI scheduler contention the stop()/stream await-chain can exceed a 2s
/// wall-clock deadline (issue #172). The coordinator stop-funnel is race-free (isStopping flips
/// synchronously before the first await), so a larger budget cannot mask a hang — it still fails, later.
@MainActor
private func eventuallyMain(timeoutMs: Int = 8000, _ condition: () -> Bool) async -> Bool {
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
    @Test("start → phase=.recording, checklist captured, windows choreographed, notifier called")
    func start_transitionsToRecording() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let notifier = FakeRecordingStartNotifier()
        var openedRecording = false
        var dismissedMain = false
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake }, notifier: notifier)
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
        #expect(coordinator.checklist.screenDescription == "1280×720 @ 60 Гц")
        #expect(coordinator.checklist.cameraDescription == "FaceTime HD · 1080p30")
        #expect(coordinator.checklist.microphoneDescription == "MacBook Pro — микрофон")
        // #242 — menu-bar-first: recording window is NOT opened automatically on start.
        #expect(!openedRecording, "recording window must NOT open on start (menu-bar-first, #242)")
        #expect(dismissedMain, "main window must hide on start (AC-3)")
        #expect(notifier.notifyCallCount == 1, "start notifier must fire exactly once")

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
        let ticked = await eventuallyMain(timeoutMs: 8000) { coordinator.elapsed >= 1 }
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
        #expect(revealed?.count == 1, "session folder must be revealed in Finder")
        #expect(revealed?.first?.lastPathComponent == "onset-fake-session", "revealed URL is the session directory")
    }

    @Test("stop → phase returns to .idle when started from the menu bar")
    func stop_returnsToIdleOrigin() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request(origin: .menuBar))
        await coordinator.stop()

        #expect(coordinator.phase == .idle, "menu-bar origin → return to .idle")
    }

    // MARK: - menuBar + write error opens main window (#131)

    @Test("stop menuBar + degraded drops but saved → returns to .idle, no window open, no pending alert")
    func stop_menuBarWithDegradedDrops_returnsToIdleWithoutOpeningWindow() async throws {
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: 64)
        )
        let openCounter = Counter()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: { openCounter.increment() }
        )

        try await coordinator.start(CoordinatorFixtures.request(origin: .menuBar))
        await coordinator.stop()

        #expect(coordinator.phase == .idle, "degraded but saved menu-bar stop → return to .idle origin")
        #expect(openCounter.value == 0, "degraded drops no longer open the main window")
        #expect(!coordinator.hasPendingAlert, "degraded warning removed → nothing to present")
    }

    @Test("stop menuBar + write error → opens main window so alert can be presented (#131)")
    func stop_menuBarWithWriteError_opensMainWindow() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.failedWriteResult())
        let openCounter = Counter()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: { openCounter.increment() }
        )

        try await coordinator.start(CoordinatorFixtures.request(origin: .menuBar))
        await coordinator.stop()

        #expect(coordinator.phase == .main, "menuBar + write error → must open main window (phase .main)")
        #expect(openCounter.value == 1, "openMainWindow must be called exactly once")
        #expect(coordinator.hasPendingAlert, "hasPendingAlert must still be true until user acknowledges")
    }

    @Test("stop computes the degraded warning from the result")
    func stop_computesDegradedWarning() async throws {
        // 128 backpressure drops is well above the default postStopDropWarningThreshold (5) —
        // lastDegradedWarning must be true because lastDroppedFrames >= threshold.
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: 128, sessionEverDegraded: false)
        )
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == true, "128 drops >= threshold → warning fires")
        #expect(coordinator.lastDroppedFrames == 128, "lastDroppedFrames must be the frozen snapshot from stop()")
        #expect(coordinator.drops.encoderBackpressureDrops == 128, "final drops come from the result")
    }

    @Test("stop produces no degraded warning when backpressure drops are below postStopDropWarningThreshold")
    func stop_noDegradedWarning_whenDropsBelowThreshold() async throws {
        // AC-9 regression guard (#132): a single isolated backpressure drop (count=1) must NOT fire
        // the post-stop alert — the threshold (default 5) must be reached cumulatively.
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: 1, sessionEverDegraded: false)
        )
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == false, "single drop is below threshold — no warning")
        #expect(coordinator.lastDroppedFrames == 1, "lastDroppedFrames still tracked for reference")
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
        let ticked = await eventuallyMain(timeoutMs: 8000) { coordinator.elapsed >= 1 }
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
        // Session 1: result carries 64 backpressure drops — well above the default threshold (5).
        let fake1 = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: 64, sessionEverDegraded: true)
        )
        // Session 2 fake is returned on the second factory call (stateful factory box, see Counter pattern).
        let fake2 = FakeRecordingControlling(
            result: CoordinatorFixtures.result()
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
        #expect(coordinator.lastDroppedFrames == 64, "lastDroppedFrames must hold the frozen snapshot from stop()")

        // Acknowledge: flag and counter must clear.
        coordinator.acknowledgeDegradedWarning()
        #expect(coordinator.lastDegradedWarning == false, "flag must be false after acknowledgeDegradedWarning()")
        #expect(coordinator.lastDroppedFrames == 0, "lastDroppedFrames must be 0 after acknowledgeDegradedWarning()")

        // --- Session 2 on the SAME coordinator: clean result must not carry flag forward ---
        // This exercises the FIX 2 reset in start(): lastDegradedWarning must be false at the
        // start of every new session as a structural invariant, not just because fake2 is clean.
        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        // The flag must be false — same coordinator, so FIX 2 reset in start() is exercised.
        #expect(coordinator.lastDegradedWarning == false, "no stale degraded flag on same-instance second session")
        #expect(coordinator.lastDroppedFrames == 0, "lastDroppedFrames must be 0 after clean second session")
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

// MARK: - .writerFailed live-UI seam (#197)

@Suite("RecordingCoordinator — writerFailed live-UI seam (#197)")
@MainActor
struct RecordingCoordinatorWriterFailedTests {
    @Test(".writerFailed(.screen) → screen liveness false, camera + mic unchanged, phase still .recording")
    func screenWriterFailed_flipsScreenLiveness() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.sourceLiveness == .allLive, "starts fully live")

        fake.emitRevocation(.writerFailed(.screen))

        let settled = await eventuallyMain { coordinator.sourceLiveness.screen == false }
        #expect(settled, "screen liveness must flip to false after .writerFailed(.screen)")
        #expect(coordinator.sourceLiveness.camera, "camera liveness must remain true")
        #expect(coordinator.sourceLiveness.microphone, "mic liveness must remain true")
        #expect(coordinator.phase == .recording, "phase must remain .recording — recording continues")

        await coordinator.stop()
    }

    @Test(".writerFailed(.camera) → camera + mic liveness false, screen unchanged, phase still .recording")
    func cameraWriterFailed_flipsCameraAndMicLiveness() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.sourceLiveness == .allLive, "starts fully live")

        fake.emitRevocation(.writerFailed(.camera))

        let cameraSettled = await eventuallyMain { coordinator.sourceLiveness.camera == false }
        #expect(cameraSettled, "camera liveness must flip to false after .writerFailed(.camera)")
        #expect(!coordinator.sourceLiveness.microphone, "mic liveness must flip to false (rides camera session)")
        #expect(coordinator.sourceLiveness.screen, "screen liveness must remain true")
        #expect(coordinator.phase == .recording, "phase must remain .recording — screen still records")

        await coordinator.stop()
    }
}

// MARK: - Screen consent ordering fix (#171)

/// Tests for the fix that gates recording UI on the first real screen frame.
///
/// On macOS 26 `SCStream.startCapture()` returns before the user grants consent. The coordinator
/// must NOT transition to `.recording`, start the elapsed timer, or open the recording window until
/// the first real screen frame arrives (`captureActiveStream` yields). These tests exercise:
///
/// 1. Phase stays pre-recording until activation signal arrives.
/// 2. Consent denied / stream terminal-stop → clean revert, `.captureDidNotActivate` thrown.
/// 3. Timeout (stream never yields, never finishes) → clean revert, `.captureDidNotActivate` thrown.
/// 4. User-cancel during consent wait → clean revert, no error thrown.
///
/// Each test controls the activation timing manually by setting
/// `fake.simulateCaptureNeverActivates = true` and calling `emitCaptureActive()` or
/// `finishCaptureActiveWithoutActivation()` at the right moment.
@Suite("RecordingCoordinator — screen consent ordering (#171)")
@MainActor
struct RecordingCoordinatorConsentOrderingTests {
    @Test("start does not transition to .recording until captureActiveStream yields")
    func start_doesNotTransitionToRecording_beforeFirstFrame() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        // Suppress auto-emit so we control exactly when activation fires.
        fake.simulateCaptureNeverActivates = true

        var openedRecording = false
        var dismissedMain = false
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })
        coordinator.bindWindowActions(
            openRecordingWindow: { openedRecording = true },
            dismissMainWindow: { dismissedMain = true },
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        // Launch start() but do NOT await it yet — activation has not fired.
        let startTask = Task { try await coordinator.start(CoordinatorFixtures.request()) }

        // Give the task a chance to run up to the activation wait.
        // The 50 ms sleep is necessary here: we must observe the state *while suspended in the wait*,
        // so there is an inherent ordering dependency on the Task being scheduled first.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Phase must still be pre-recording and UI must not have opened.
        #expect(coordinator.phase != .recording, "phase must not flip to .recording before first frame (#171)")
        #expect(coordinator.elapsed == 0, "elapsed must be 0 before first frame (#171)")
        #expect(!openedRecording, "recording window must not open before first frame (#171)")
        #expect(!dismissedMain, "main window must not dismiss before first frame (#171)")

        // Now signal activation — coordinator must transition.
        fake.emitCaptureActive()

        try await startTask.value

        #expect(coordinator.phase == .recording, "phase must flip to .recording after first frame")
        // #242 — menu-bar-first: recording window is never opened automatically.
        #expect(!openedRecording, "recording window must NOT open, even after first frame (menu-bar-first, #242)")
        #expect(dismissedMain, "main window must dismiss after first frame")
        // Fix #6: startedAt must be set — timer anchors to first-frame time.
        #expect(coordinator.startedAt != nil, "startedAt must be set after activation (#171)")

        await coordinator.stop()
    }

    @Test("start reverts promptly on deny/terminal-stop — not after full timeout (fix #1 regression)")
    func start_revertsToPreRecording_onDenyOrTerminalStop() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.simulateCaptureNeverActivates = true

        // Use a LARGE timeout (100 s) so that if stream-finish is NOT the trigger, the test would
        // block for 100 s (deterministic proof that fix #1 drives the revert, not the timeout).
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            activationTimeoutSeconds: 100
        )
        coordinator.enterMain()

        var openedRecording = false
        coordinator.bindWindowActions(
            openRecordingWindow: { openedRecording = true },
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        // Launch start() — it will wait for activation.
        let startTask = Task {
            try await coordinator.start(CoordinatorFixtures.request())
        }

        // Give the task a chance to enter the activation wait.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Simulate consent denied: stream finishes without yielding.
        // The revert must happen PROMPTLY (not after the 100-second timeout).
        fake.finishCaptureActiveWithoutActivation()

        // start() must throw .captureDidNotActivate (renamed from captureConsentDenied).
        var threwCaptureDidNotActivate = false
        do {
            try await startTask.value
        } catch let error as RecordingError {
            if case .captureDidNotActivate = error { threwCaptureDidNotActivate = true }
        }

        #expect(
            threwCaptureDidNotActivate,
            "start() must throw .captureDidNotActivate when stream ends without activation"
        )
        #expect(coordinator.phase == .main, "phase must revert to pre-recording state after deny")
        #expect(!openedRecording, "recording window must NOT have opened")
        #expect(coordinator.elapsed == 0, "elapsed must be 0 — timer must not have started")
        // Fix #6: session must have been stopped exactly once (no leak).
        #expect(fake.stopCount == 1, "session must be stopped exactly once — no leak (#2)")
    }

    @Test("start reverts on timeout when captureActiveStream never yields and never finishes")
    func start_revertsOnTimeout_whenStreamNeverActivates() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        // simulateCaptureNeverActivates=true AND never call finishCaptureActiveWithoutActivation
        // → stream hangs forever. The injected tiny timeout drives the revert.
        fake.simulateCaptureNeverActivates = true

        // Use a tiny timeout (50 ms) so the test does not take 30 s.
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            activationTimeoutSeconds: 0.05
        )
        coordinator.enterMain()

        var threwCaptureDidNotActivate = false
        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch let error as RecordingError {
            if case .captureDidNotActivate = error { threwCaptureDidNotActivate = true }
        }

        #expect(threwCaptureDidNotActivate, "start() must throw .captureDidNotActivate on activation timeout")
        #expect(coordinator.phase == .main, "phase must revert to .main after timeout")
        #expect(coordinator.session == nil, "session must be nil after timeout — no leak (#2)")
    }

    @Test("stop() during consent wait reverts silently — no error thrown to caller")
    func stop_duringConsentWait_revertsWithoutError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.simulateCaptureNeverActivates = true

        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            activationTimeoutSeconds: 100
        )
        coordinator.enterMain()

        let startTask = Task {
            try await coordinator.start(CoordinatorFixtures.request())
        }

        // Give start() a chance to reach the activation wait.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // User cancels by pressing stop — must NOT produce an error alert.
        await coordinator.stop()

        var threwError = false
        do {
            try await startTask.value
        } catch {
            threwError = true
        }

        #expect(!threwError, "stop() during consent wait must not surface an error to the caller")
        #expect(coordinator.phase == .main, "phase must return to .main after user cancel")
        #expect(coordinator.session == nil, "session must be nil after user cancel — no leak (#2)")
    }

    // MARK: Fix 2 regression tests

    /// Scenario (b): stop() arrives while session.start() is still suspended — activationTask is
    /// nil at that point so Task.cancel() is a no-op. The cancel flag must survive the resume and
    /// trigger a silent revert (phase stays .main, no error thrown).
    ///
    /// This is the regression test that catches the old bug: the original code reset
    /// `activationCancelledByUser = false` at the TOP of the activation block (after the
    /// `session.start()` await) — wiping the flag set by stop() and letting recording proceed.
    @Test("stop() during session.start() suspension reverts silently (Fix 2b — no activationTask wipe)")
    func stop_duringSessionStartSuspension_revertsWithoutError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        // Gate session.start() so stop() can race it while activationTask is still nil.
        fake.gateStartEnabled = true

        var openedRecording = false
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            activationTimeoutSeconds: 100
        )
        coordinator.enterMain()
        coordinator.bindWindowActions(
            openRecordingWindow: { openedRecording = true },
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        // Launch start() — it will suspend inside fake.start() (activationTask is nil here).
        let startTask = Task {
            try await coordinator.start(CoordinatorFixtures.request())
        }

        // Give start() a chance to reach the gate suspension.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // stop() sets activationCancelledByUser = true; activationTask is still nil so cancel is
        // a no-op — this is the exact race that the old reset wiped.
        await coordinator.stop()

        // Unblock session.start() — auto-emit will fire (simulateCaptureNeverActivates is false)
        // so captureActivated == true. The fix must catch the flag BEFORE the guard and revert.
        fake.releaseStart()

        var threwError = false
        do {
            try await startTask.value
        } catch {
            threwError = true
        }

        #expect(!threwError, "stop() during session.start() must revert silently, not throw")
        #expect(coordinator.phase == .main, "phase must be .main after silent revert")
        #expect(!openedRecording, "recording window must NOT open after cancel during session.start()")
        // stop() in isStarting mode only calls cancelActivation() (does not stop the session itself);
        // the fix adds session.stop() in the pre-guard cancel branch → stopCount == 1.
        #expect(fake.stopCount == 1, "session must be stopped exactly once")
    }

    /// Scenario (a) deterministic variant: stop() races the activation wait after the stream has
    /// already yielded. Implemented via the start-gate (same seam as scenario b) so the timing is
    /// deterministic: gate keeps session.start() in suspension; stop() sets the flag; releaseStart()
    /// fires auto-emit (captureActivated == true); pre-guard check catches the flag → silent revert.
    ///
    /// Note: the pure success-path race (stop after activationTask.value but before resume) has no
    /// fake seam and is not representable deterministically — both tests fold through the start-gate.
    @Test("stop() after activation yielded true reverts silently — pre-guard cancel check (Fix 2a)")
    func stop_afterActivationYielded_revertsWithoutError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        // Gate start() — same seam; after releaseStart() auto-emit fires giving captureActivated=true.
        fake.gateStartEnabled = true

        var openedRecording = false
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in fake },
            activationTimeoutSeconds: 100
        )
        coordinator.enterMain()
        coordinator.bindWindowActions(
            openRecordingWindow: { openedRecording = true },
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )

        let startTask = Task {
            try await coordinator.start(CoordinatorFixtures.request())
        }

        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Set the cancel flag while start() is still suspended.
        await coordinator.stop()

        // Release the gate — captureActivated will be true; fix must revert via the pre-guard check.
        fake.releaseStart()

        var threwError = false
        do {
            try await startTask.value
        } catch {
            threwError = true
        }

        #expect(!threwError, "stop() before activation completes must revert silently, not throw")
        #expect(coordinator.phase == .main, "phase must be .main after cancel-flag revert")
        #expect(!openedRecording, "recording window must NOT open when cancel flag is set")
    }
}

// MARK: - Critical signals (critical-recording-signals, Phase C)

/// L2 for the coordinator's critical-signal wiring: scope→tier mapping, de-escalation, the two
/// values (live view vs session latch), live-notification dedupe + severity-override + session cap,
/// and the post-stop summary branch.
///
/// The pure detectors (`FpsCollapseDetector` / `SustainedDropDetector`) are tested in isolation in
/// their own suites — here the across-tick state machine is driven by DIRECT synchronous calls to
/// `stepCriticalDetectors` / `dispatchLiveNotification` / `handleCameraLoss`, the only deterministic
/// way to exercise de-escalation / cap / override (the live 1 Hz loop's `Task.sleep` is
/// non-deterministic, and the soft→hard path is unreachable through the revocation streams).
@Suite("RecordingCoordinator — critical signals (Phase C)")
@MainActor
struct RecordingCoordinatorCriticalTests {
    private static let sustainSeconds = RecordingConfiguration.mvpDefault.criticalSustainSeconds
    private static let dedupeSeconds = RecordingConfiguration.mvpDefault.criticalNotificationDedupeSeconds

    private func makeCoordinator(
        notifier: FakeRecordingStartNotifier
    )
    -> RecordingCoordinator {
        RecordingCoordinator(
            sessionFactory: { _ in FakeRecordingControlling(result: CoordinatorFixtures.result()) },
            notifier: notifier
        )
    }

    // MARK: - AC-1 / AC-2 scope → tier mapping

    @Test("AC-1: cameraAndScreen loss → soft, active notification, NO latch (screen track intact)")
    func cameraLoss_cameraAndScreen_isSoftNoLatch() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        coordinator.handleCameraLoss(scope: .cameraAndScreen)

        #expect(coordinator.liveCriticalView == .cameraLost(scope: .cameraAndScreen), "soft view surfaced")
        #expect(coordinator.sessionMaxSeverityLatch == .soft, "session latch climbs to soft")
        #expect(notifier.criticalIncidents == [.cameraLost(scope: .cameraAndScreen)], "one soft incident")
        #expect(notifier.criticalIncidentLevels == [.active], "soft → active interruption level")
    }

    @Test("AC-2: cameraOnly loss → hard, timeSensitive notification, view latched")
    func cameraLoss_cameraOnly_isHardLatched() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        coordinator.handleCameraLoss(scope: .cameraOnly)

        #expect(coordinator.liveCriticalView == .cameraLost(scope: .cameraOnly), "hard terminal view latched")
        #expect(coordinator.sessionMaxSeverityLatch == .hard, "session latch climbs to hard")
        #expect(notifier.criticalIncidentLevels == [.timeSensitive], "hard → timeSensitive interruption level")
    }

    @Test("AC-1: soft camera-loss view persists across a quiet detector tick (a11y must not flicker)")
    func cameraLoss_softView_persistsAcrossQuietTick() {
        let coordinator = self.makeCoordinator(notifier: FakeRecordingStartNotifier())

        coordinator.handleCameraLoss(scope: .cameraAndScreen)
        // A quiet detector tick (not degraded, no rates) must NOT wipe the sticky soft view.
        coordinator.stepCriticalDetectors(isDegraded: false, rates: nil, monotonicElapsed: 1)

        #expect(
            coordinator.liveCriticalView == .cameraLost(scope: .cameraAndScreen),
            "soft camera-loss view is one-shot/sticky — a quiet tick must not clear it (AC-1)"
        )
    }

    // MARK: - AC-3(в) de-escalation + two-value split

    @Test("AC-3(в): windowed-hard fires then recovers → live view de-escalates, session latch retained")
    func sustainedDrops_deEscalates_butLatchRetainedForPostStop() {
        let coordinator = self.makeCoordinator(notifier: FakeRecordingStartNotifier())

        // Degraded held continuously past the sustain threshold → fires (windowed-hard live view).
        coordinator.stepCriticalDetectors(isDegraded: true, rates: nil, monotonicElapsed: 0)
        coordinator.stepCriticalDetectors(isDegraded: true, rates: nil, monotonicElapsed: Self.sustainSeconds + 1)
        #expect(coordinator.liveCriticalView == .sustainedDrops, "fires while degraded holds past threshold")
        #expect(coordinator.sessionMaxSeverityLatch == .hard, "session latch climbs to hard")

        // Recovery: degraded clears → live view de-escalates to nil; session latch is retained.
        coordinator.stepCriticalDetectors(isDegraded: false, rates: nil, monotonicElapsed: Self.sustainSeconds + 2)
        #expect(coordinator.liveCriticalView == nil, "live view de-escalates on recovery (no stuck fire)")
        #expect(coordinator.sessionMaxSeverityLatch == .hard, "session latch retains hard for the post-stop branch")
    }

    @Test("AC-8: sub-threshold degraded → no live view, latch empty, notifier never called")
    func subThresholdDegraded_staysQuiet() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        // Degraded but well under the sustain threshold (transient) → no fire.
        coordinator.stepCriticalDetectors(isDegraded: true, rates: nil, monotonicElapsed: 0)
        coordinator.stepCriticalDetectors(isDegraded: true, rates: nil, monotonicElapsed: Self.sustainSeconds - 1)

        #expect(coordinator.liveCriticalView == nil, "transient degraded → no critical view")
        #expect(coordinator.sessionMaxSeverityLatch == nil, "latch stays empty for sub-threshold")
        #expect(notifier.criticalIncidents.isEmpty, "Fake notifier must NOT be called for sub-threshold drops (#246)")
    }

    // MARK: - AC-9 dedupe + severity override

    @Test("AC-9: two hard incidents inside the dedupe window → one notification (suppress)")
    func dedupe_twoHardInWindow_oneNotification() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        coordinator.dispatchLiveNotification(.sustainedDrops, monotonicElapsed: 0)
        coordinator.dispatchLiveNotification(.fpsCollapse, monotonicElapsed: 1) // inside window, same tier

        #expect(notifier.criticalIncidents == [.sustainedDrops], "second hard in window is suppressed")
    }

    @Test("AC-9: soft shown, then hard inside window → hard delivered via severity-override")
    func dedupe_softThenHard_hardOverrides() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        coordinator.dispatchLiveNotification(.cameraLost(scope: .cameraAndScreen), monotonicElapsed: 0)
        coordinator.dispatchLiveNotification(.sustainedDrops, monotonicElapsed: 1) // higher tier, in window

        #expect(
            notifier.criticalIncidents == [.cameraLost(scope: .cameraAndScreen), .sustainedDrops],
            "a hard tier breaks through a window opened by a soft (severity-override)"
        )
        #expect(notifier.criticalIncidentLevels == [.active, .timeSensitive])
    }

    // MARK: - AC-3(б) session-level cap

    @Test("AC-3(б): recurrent hard after de-escalation → no second live banner (session cap)")
    func sessionCap_recurrentHard_postsOnce() {
        let notifier = FakeRecordingStartNotifier()
        let coordinator = self.makeCoordinator(notifier: notifier)

        coordinator.dispatchLiveNotification(.sustainedDrops, monotonicElapsed: 0)
        // Far outside the dedupe window (recurrence on the 30th minute) — the session cap still blocks.
        coordinator.dispatchLiveNotification(.sustainedDrops, monotonicElapsed: Self.dedupeSeconds * 200)

        #expect(notifier.criticalIncidents == [.sustainedDrops], "each tier posts at most once per session")
    }

    // MARK: - AC-10 (coordinator half): indicator independent of notification auth

    @Test("AC-10: notifier denied/no-op → live view still reflects hard; no crash")
    func deniedNotifier_indicatorStillReflectsHard() {
        // A no-op notifier stands in for the denied path (the live notifier silently drops when denied).
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in FakeRecordingControlling(result: CoordinatorFixtures.result()) },
            notifier: NoOpNotifier()
        )

        coordinator.handleCameraLoss(scope: .cameraOnly)

        #expect(
            coordinator.liveCriticalView == .cameraLost(scope: .cameraOnly),
            "indicator state is independent of notification delivery (octagon is the fallback channel)"
        )
    }

    @Test("AC-10: soft + denied notifier → no crash, disk-only by design")
    func deniedNotifier_soft_noCrash() {
        let coordinator = RecordingCoordinator(
            sessionFactory: { _ in FakeRecordingControlling(result: CoordinatorFixtures.result()) },
            notifier: NoOpNotifier()
        )

        // Must not crash; soft + denied stays disk-only by design.
        coordinator.handleCameraLoss(scope: .cameraAndScreen)
        #expect(coordinator.liveCriticalView == .cameraLost(scope: .cameraAndScreen))
    }

    // MARK: - tick loop feeds the MONOTONIC clock (item-1 guard)

    @Test("tick loop threads currentSessionElapsedSeconds() (monotonic), not Date()")
    func tickLoop_feedsMonotonicElapsed() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.liveSessionElapsedSeconds = 42 // injected monotonic clock, distinct from Date()-elapsed
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake })

        try await coordinator.start(CoordinatorFixtures.request())
        let threaded = await eventuallyMain { coordinator.lastMonotonicElapsedSeconds == 42 }
        #expect(threaded, "the tick loop must pull and thread the session's monotonic elapsed")

        await coordinator.stop()
    }
}

// MARK: - AC-13 / AC-4 / AC-8 post-stop summary

@Suite("RecordingCoordinator — post-stop critical summary (Phase C)")
@MainActor
struct RecordingCoordinatorPostStopTests {
    @Test("AC-13: soft-only session → notifyPostStopSummary(.soft), not hard")
    func postStop_softOnly_softSummary() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let notifier = FakeRecordingStartNotifier()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake }, notifier: notifier)

        try await coordinator.start(CoordinatorFixtures.request())
        // Soft camera loss during the session, no hard incident.
        fake.emitRevocation(.sourceRevoked(.camera))
        let softSeen = await eventuallyMain { coordinator.sessionMaxSeverityLatch == .soft }
        #expect(softSeen, "prerequisite: soft latch set by the camera revoke")

        await coordinator.stop()

        #expect(notifier.postStopSeverities == [.soft], "soft-only session → soft post-stop summary (not hard)")
    }

    @Test("T-E.1: post-stop summary carries the report URL inside the session folder (AC-12 wiring)")
    func postStop_carriesReportURL() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let notifier = FakeRecordingStartNotifier()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake }, notifier: notifier)

        try await coordinator.start(CoordinatorFixtures.request())
        fake.emitRevocation(.sourceRevoked(.camera))
        let softSeen = await eventuallyMain { coordinator.sessionMaxSeverityLatch == .soft }
        #expect(softSeen, "prerequisite: soft latch set by the camera revoke")

        await coordinator.stop()

        // The report URL is the session folder + the timestamped report name shared with the files.
        let expectedReportURL = URL(
            filePath: RecordingOutput.reportFileName(timestamp: fake.sessionStartDate),
            relativeTo: fake.sessionDirectory
        )
        #expect(notifier.postStopReportURLs == [expectedReportURL])
        // The deterministic deeper check: the reveal target lives inside the revealed session folder.
        #expect(
            notifier.postStopReportURLs.first??.deletingLastPathComponent().standardizedFileURL
                == fake.sessionDirectory.standardizedFileURL,
            "report URL must resolve inside the session folder so the tap reveals the on-disk report"
        )
    }

    @Test("AC-8: minor (sub-threshold) drops → no post-stop summary (disk-only, #246)")
    func postStop_minorDrops_noSummary() async throws {
        // 1 backpressure drop over a long session: well under criticalDropRatePerMin → no post-stop hard.
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: 1)
        )
        fake.liveSessionElapsedSeconds = 600 // long session; 1 drop / 10 min ≪ 600/min floor
        let notifier = FakeRecordingStartNotifier()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake }, notifier: notifier)

        try await coordinator.start(CoordinatorFixtures.request())
        _ = await eventuallyMain { coordinator.lastMonotonicElapsedSeconds == 600 }
        await coordinator.stop()

        #expect(notifier.postStopSeverities.isEmpty, "minor drops stay disk-only — no post-stop notification (#246)")
        #expect(!coordinator.hasPendingAlert, "critical post-stop must NOT force the window open (#246)")
    }

    @Test("AC-4: high drop-rate over a long session → post-stop hard summary even without live latch")
    func postStop_highDropRate_hardSummary() async throws {
        // 600 drops / 60 s = 600/min == criticalDropRatePerMin, duration well above the floor.
        let drops = RecordingConfiguration.mvpDefault.criticalDropRatePerMin
        let fake = FakeRecordingControlling(
            result: CoordinatorFixtures.result(backpressureDrops: drops)
        )
        fake.liveSessionElapsedSeconds = 60
        let notifier = FakeRecordingStartNotifier()
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake }, notifier: notifier)

        try await coordinator.start(CoordinatorFixtures.request())
        _ = await eventuallyMain { coordinator.lastMonotonicElapsedSeconds == 60 }
        await coordinator.stop()

        #expect(
            notifier.postStopSeverities == [.hard],
            "post-stop drop-rate criterion (AC-4) yields hard summary even when degraded never held continuously"
        )
    }
}

// MARK: - No-op notifier (AC-10 denied/no-delivery stand-in)

/// A `RecordingStartNotifying` that silently drops every call — stands in for the denied-notifications
/// path (the live notifier no-ops when authorization is denied). Used to prove the indicator state is
/// independent of notification delivery.
@MainActor
private final class NoOpNotifier: RecordingStartNotifying {
    func notifyRecordingStarted() {}
    func notifyCriticalIncident(_: CriticalIncident) {}
    func notifyPostStopSummary(severity _: CriticalSeverity, reportURL _: URL?) {}
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable trailing_closure
// swiftlint:enable type_body_length
