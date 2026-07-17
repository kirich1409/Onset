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

    nonisolated let captureActiveStream: AsyncStream<Void>
    private let captureActiveContinuation: AsyncStream<Void>.Continuation

    /// Fake session directory — a sentinel path used in coordinator tests.
    nonisolated let sessionDirectory = URL(filePath: "/tmp/onset-fake-session")

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

    /// When `true`, `stop()` suspends until `releaseStop()` is called — simulates an in-flight or
    /// genuinely stuck teardown (VideoToolbox flush / `finishWriting()` blocked), the #243 scenario.
    var gateStopEnabled = false
    private let (stopGateStream, stopGateContinuation) = AsyncStream.makeStream(of: Void.self)

    /// The health snapshot returned by `currentDrops()` while recording.
    var liveDrops = DropHealthSnapshot(
        counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        sessionEverDegraded: false,
        dominantCause: .notDegraded
    )

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
        if let startError {
            throw startError
        }
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
        // When gateStopEnabled, suspend here until releaseStop() — simulates a teardown that is
        // in flight (defect 1) or stuck (defect 2). stopCount is bumped BEFORE suspending so a test
        // can prove entry; the coordinator's memoized stopTask ensures this runs exactly once even
        // when a second stop path (termination) awaits the same handle.
        if self.gateStopEnabled {
            for await _ in self.stopGateStream {
                break
            }
        }
        // The live session finishes all streams on stop; mirror that so the coordinator's
        // subscription loops end deterministically.
        self.stateContinuation.finish()
        self.revocationContinuation.finish()
        self.captureActiveContinuation.finish()
        return self.result
    }

    /// Test hook: unblock a `stop()` suspension gated by `gateStopEnabled`.
    func releaseStop() {
        self.stopGateContinuation.yield(())
        self.stopGateContinuation.finish()
    }

    func currentDrops() async -> DropHealthSnapshot {
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
        if condition() {
            return true
        }
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
            notifier: notifier
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == false, "single drop is below threshold — no warning")
        #expect(coordinator.lastDroppedFrames == 1, "lastDroppedFrames still tracked for reference")
    }

    @Test("stop is idempotent across concurrent paths — teardown runs once")
    func stop_idempotentAcrossPaths() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                factoryCounter.increment()
                return fake
            }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                callCounter.increment()
                return callCounter.value == 1 ? fake1 : fake2
            }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastWriteError != nil, "lastWriteError must be set when a writer finishes .failed")

        coordinator.acknowledgeWriteError()
        #expect(coordinator.lastWriteError == nil, "lastWriteError must clear after acknowledgeWriteError()")
    }

    @Test("stop with clean result leaves lastWriteError nil")
    func stop_cleanResult_noWriteError() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastWriteError == nil, "lastWriteError must be nil when all writers succeed")
    }

    @Test("start resets lastWriteError from previous session")
    func start_resetsWriteError() async throws {
        let fake1 = FakeRecordingControlling(result: CoordinatorFixtures.failedWriteResult())
        let fake2 = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let callCounter2 = Counter()
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                callCounter2.increment()
                return callCounter2.value == 1 ? fake1 : fake2
            }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
        coordinator.enterMain() // begin in .main

        var threw = false
        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch let error as RecordingError {
            if case .noVideoSource = error {
                threw = true
            }
        }

        #expect(threw, "start() must rethrow the RecordingError for the UI to surface (AC-6/AC-11)")
        #expect(coordinator.phase == .main, "phase must be unchanged after a failed start")
    }

    // MARK: - menuBarRecordIntent seam (#38)

    @Test("menuBarRecordIntent seam — installed closure is invoked")
    func menuBarRecordIntent_installedClosureRuns() {
        // Verifies that the coordinator stores and dispatches the intent closure exactly as set.
        // This is the seam wiring test: MainView installs the closure; this proves it fires.
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                FakeRecordingControlling(result: CoordinatorFixtures.result())
            }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                FakeRecordingControlling(result: CoordinatorFixtures.result())
            }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                callCounter.increment()
                return callCounter.value == 1 ? fake1 : fake2
            }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in
                FakeRecordingControlling(result: CoordinatorFixtures.result())
            }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

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
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
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
            if case .captureDidNotActivate = error {
                threwCaptureDidNotActivate = true
            }
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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
            activationTimeoutSeconds: 0.05
        )
        coordinator.enterMain()

        var threwCaptureDidNotActivate = false
        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch let error as RecordingError {
            if case .captureDidNotActivate = error {
                threwCaptureDidNotActivate = true
            }
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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
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
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
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

    // MARK: - Default sessionFactory wiring

    @Test("defaultSessionFactory_buildsRecordingSessionFromResolvedSelection")
    func defaultSessionFactory_buildsRecordingSessionFromResolvedSelection() {
        // Constructs a coordinator WITHOUT injecting sessionFactory so the PRODUCTION default
        // closure (the one that switches on resolved.encoder/source/writer and builds Live*
        // factories) is stored. Calls that closure directly with a known ResolvedBackendSelection
        // and asserts it produces a RecordingSession — exercising the resolved→factory wiring
        // without calling session.start() (which would touch capture hardware).
        //
        // The switch today always yields .live for every stage (single-case enums), so this cannot
        // behaviourally distinguish "consumes resolved" from "ignores it" until a second backend
        // case is added. The test is forward-looking: it guards the wiring and will catch a
        // regression the moment another case exists.
        let coordinator = RecordingCoordinator {
            UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults())
        }
        let resolved = ResolvedBackendSelection(source: .live, encoder: .live, writer: .live)
        let session = coordinator.sessionFactory(CoordinatorFixtures.request(), resolved)
        #expect(session is RecordingSession, "production default sessionFactory must produce a RecordingSession")
    }
}

// MARK: - isRecordingActive gate (Settings T-8 — recording-affecting controls)

/// Tests for the `isRecordingActive` observable gate that `ControlAvailability` reads to grey out
/// settings whose `SettingApplyPolicy` is `.nextRecordingStart` during an active recording.
///
/// The contract (see the property doc on `RecordingCoordinator.isRecordingActive`): `true` from the
/// ENTRY of `start()` through the COMPLETION of `stop()` — covering the whole startup window plus the
/// recording — and `false` once fully stopped OR after any start that reverts. The three reset sites
/// are exercised here: the `session.start()` catch, the `if !activated` cleanup defer
/// (denial / timeout / user-cancel), and the end of `stop()`. The `isStarting` `defer` must NOT
/// reset it — otherwise the gate would drop to `false` on the success path mid-start.
@Suite("RecordingCoordinator — isRecordingActive gate (Settings T-8)")
@MainActor
struct RecordingCoordinatorActiveGateTests {
    @Test("isRecordingActive is false when idle")
    func isRecordingActive_falseWhenIdle() {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        #expect(!coordinator.isRecordingActive, "gate must be false before any recording starts")
    }

    @Test("isRecordingActive becomes true across the start window — before phase == .recording")
    func isRecordingActive_trueAcrossStartWindow() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        // Suppress auto-emit so start() stays in the activation wait and we can observe the gate
        // while isStarting is still true and phase has not yet flipped to .recording.
        fake.simulateCaptureNeverActivates = true
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        // Launch start() without awaiting — it suspends in the activation wait.
        let startTask = Task { try await coordinator.start(CoordinatorFixtures.request()) }
        // Let the task run up to the activation wait (same ordering dependency as the #171 tests).
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // The gate must already be true mid-start, even though phase has not reached .recording.
        #expect(coordinator.phase != .recording, "prerequisite: still in the start window")
        #expect(coordinator.isRecordingActive, "gate must be true across the whole start window (set at entry)")

        // Activation fires → start() completes; the success path leaves the gate true.
        fake.emitCaptureActive()
        try await startTask.value
        #expect(coordinator.phase == .recording, "prerequisite: now recording")
        #expect(coordinator.isRecordingActive, "gate must remain true while recording (success path)")

        await coordinator.stop()
    }

    @Test("isRecordingActive returns to false after a normal stop()")
    func isRecordingActive_falseAfterNormalStop() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.isRecordingActive, "prerequisite: gate is true while recording")

        await coordinator.stop()
        #expect(!coordinator.isRecordingActive, "gate must reset to false after a normal stop()")
    }

    @Test("isRecordingActive resets to false when session.start() throws (catch path)")
    func isRecordingActive_falseOnSessionStartError() async {
        // Exercises the reset in the `session.start()` catch block — the gate is set true at entry,
        // so a throw before activation must not leave it stuck true.
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.startError = RecordingError.noVideoSource
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )

        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch {
            // Expected — the session refused to start.
        }

        #expect(!coordinator.isRecordingActive, "gate must reset to false when session.start() throws")
    }

    @Test("isRecordingActive resets to false on a start that never activates (timeout)")
    func isRecordingActive_falseOnActivationTimeout() async {
        // Exercises the `if !activated` cleanup defer: capture never activates and the bounded
        // timeout fires, so start() throws .captureDidNotActivate and the gate must revert.
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.simulateCaptureNeverActivates = true
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
            activationTimeoutSeconds: 0.05
        )

        do {
            try await coordinator.start(CoordinatorFixtures.request())
        } catch {
            // Expected — capture did not activate.
        }

        #expect(!coordinator.isRecordingActive, "gate must reset to false after an activation timeout")
    }

    @Test("isRecordingActive resets to false when stop() cancels the consent wait")
    func isRecordingActive_falseOnUserCancelDuringConsentWait() async throws {
        // Exercises the `if !activated` cleanup defer via the user-cancel path: stop() during the
        // consent wait reverts silently, and the gate must not be left stuck true.
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.simulateCaptureNeverActivates = true
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake },
            activationTimeoutSeconds: 100
        )
        coordinator.enterMain()

        let startTask = Task { try await coordinator.start(CoordinatorFixtures.request()) }
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // User cancels mid-consent — silent revert.
        await coordinator.stop()
        try await startTask.value

        #expect(!coordinator.isRecordingActive, "gate must reset to false after a user cancel during consent wait")
    }
}

// MARK: - Termination finalization (#243)

/// Regression coverage for #243: graceful app termination (Cmd-Q / Dock Quit) during an active
/// recording must await the normal `stop()` teardown instead of falling straight through to
/// `movieFragmentInterval` fragment-recovery. Exercises `RecordingCoordinator.finalizeForTermination`
/// directly — the injectable seam `AppDelegate.applicationShouldTerminate(_:)` calls into — rather
/// than driving `NSApplication` itself.
@Suite("RecordingCoordinator — finalizeForTermination (#243)")
@MainActor
struct RecordingCoordinatorTerminationTests {
    @Test("active recording — finalizeForTermination awaits stop() before returning")
    func finalizeForTermination_activeRecording_awaitsStop() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )
        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.phase == .recording, "prerequisite: must be recording")

        await coordinator.finalizeForTermination()

        // stop() was awaited to completion — not merely called and left in flight — the
        // coordinator's own post-stop state (isRecordingActive gate, stopCount) proves it ran to
        // the end rather than racing finalizeForTermination's return.
        #expect(fake.stopCalled, "stop() must be called when a recording is active at termination")
        #expect(fake.stopCount == 1, "stop() must be awaited exactly once, not left running unawaited")
        #expect(
            !coordinator.isRecordingActive,
            "gate must be false — finalizeForTermination awaited stop() to completion"
        )
    }

    @Test("no active recording — finalizeForTermination returns immediately without calling stop()")
    func finalizeForTermination_noActiveRecording_doesNotCallStop() async {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
        coordinator.enterMain()
        #expect(!coordinator.isRecordingActive, "prerequisite: idle, no recording started")

        await coordinator.finalizeForTermination()

        #expect(!fake.stopCalled, "stop() must not be called — the regression is an UNCONDITIONAL await, not a no-op")
    }

    /// #243 defect 1: a stop() is ALREADY in flight (user/hotkey/menu/.allVideoSourcesLost) when
    /// termination fires. The old finalize started a FRESH guarded stop() that no-op'd against
    /// isStopping and returned instantly, letting the process terminate mid-teardown. finalize must
    /// instead await the SAME in-flight teardown handle.
    @Test("in-flight teardown at termination — finalize awaits THAT teardown, not a fresh no-op stop()")
    func finalizeForTermination_awaitsInFlightTeardown() async throws { // swiftlint:disable:this function_body_length
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.gateStopEnabled = true
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )
        try await coordinator.start(CoordinatorFixtures.request())
        #expect(coordinator.phase == .recording, "prerequisite: must be recording")

        // A user/hotkey/auto stop is already in flight, suspended on the fake's stop gate.
        let inFlightStop = Task { await coordinator.stop() }
        // Let the in-flight teardown reach the gate. The teardown Task first joins the cancelled
        // tick loop before calling the gated session.stop(), so poll rather than assume one yield.
        var spins = 0
        while !fake.stopCalled, spins < 1000 {
            await Task.yield()
            spins += 1
        }
        #expect(fake.stopCalled, "prerequisite: an in-flight teardown entered and suspended on the gate")

        // Termination fires while that teardown is still running.
        var finalizeReturned = false
        let finalizeTask = Task {
            await coordinator.finalizeForTermination()
            finalizeReturned = true
        }

        // finalize must NOT return while the in-flight teardown is still gated — it awaits the SAME
        // handle. (A no-op fresh stop() would return here — the old-code regression.)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(
            !finalizeReturned,
            "finalize returned before the in-flight teardown finished — it no-op'd instead of awaiting the real handle"
        )

        // Complete the in-flight teardown; finalize must now return.
        fake.releaseStop()
        await finalizeTask.value
        await inFlightStop.value

        #expect(finalizeReturned, "finalize must return once the awaited in-flight teardown completes")
        #expect(
            fake.stopCount == 1,
            "session.stop() invoked exactly once — finalize awaited the shared handle, not a second stop"
        )
        #expect(!coordinator.isRecordingActive, "gate cleared — the teardown finalize awaited ran to completion")
    }

    /// #243 defect 2: a genuinely stuck teardown (VideoToolbox flush / finishWriting() blocked —
    /// exactly what the bound exists for). finalize must ABANDON at the deadline and return, so
    /// applicationShouldTerminate's reply(true) fires and quit proceeds bounded — never hangs.
    @Test("stuck teardown — finalizeForTermination abandons at the deadline instead of hanging")
    func finalizeForTermination_stuckTeardown_returnsWithinTimeout() async throws {
        let fake = FakeRecordingControlling(result: CoordinatorFixtures.result())
        fake.gateStopEnabled = true // teardown suspends and is never released before assertions
        let coordinator = RecordingCoordinator(
            makeBackendStore: { UserDefaultsBackendSelectionStore(defaults: InMemoryUserDefaults()) },
            sessionFactory: { _, _ in fake }
        )
        coordinator.bindWindowActions(
            openRecordingWindow: {},
            dismissMainWindow: {},
            dismissRecordingWindow: {},
            openMainWindow: {}
        )
        try await coordinator.start(CoordinatorFixtures.request())
        // Drain the orphaned (abandoned) teardown after the assertions so it does not linger blocked.
        defer { fake.releaseStop() }

        let timeout: Duration = .milliseconds(50)
        let clock = ContinuousClock()
        let start = clock.now

        // Reply-exactly-once: finalize does not call NSApp.reply itself — AppDelegate does, once,
        // after this single await returns. The internal CheckedContinuation is resumed exactly once
        // (TerminationGate), so finalize returns exactly once on every path; a double-resume would
        // trap the process, so reaching the assertion below proves resume-once held.
        await coordinator.finalizeForTermination(timeout: timeout)
        let elapsed = clock.now - start

        // Returned bounded — abandoned the stuck teardown at the deadline rather than hanging on the
        // non-cancellable finishWriting(). Generous slack absorbs scheduler jitter under parallel test load.
        #expect(
            elapsed < timeout + .milliseconds(500),
            "finalize must return ~within the timeout, not hang on the stuck teardown"
        )
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable type_body_length
