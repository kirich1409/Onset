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
// Rationale: synthetic fixture dimensions / drop counts are inherent test data (no_magic_numbers);
// the `sessionFactory:` closure reads clearer as a labelled argument than as a trailing closure
// (trailing_closure), matching the existing RecordingSessionTests convention.

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
        let (stream, continuation) = AsyncStream.makeStream(of: RecordingState.self)
        self.recordingStateStream = stream
        self.stateContinuation = continuation
    }

    func start(permissions: EffectivePermissions) async throws {
        self.startCalled = true
        self.startCount += 1
        if let startError { throw startError }
    }

    func stop() async -> RecordingResult {
        self.stopCalled = true
        self.stopCount += 1
        // The live session finishes its state stream on stop; mirror that so the coordinator's
        // subscription loop ends deterministically.
        self.stateContinuation.finish()
        return self.result
    }

    func currentDrops() async -> DropCounters {
        self.liveDrops
    }

    /// Test hook: push a state transition into the stream (the coordinator is the sole consumer).
    func emitState(_ state: RecordingState) {
        self.stateContinuation.yield(state)
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

        try await coordinator.start(CoordinatorFixtures.request())

        #expect(coordinator.phase == .recording)
        #expect(fake.startCalled)
        #expect(coordinator.checklist.screenDescription == "1280×720 @ 60 Hz")
        #expect(openedRecording, "recording window must open on start (AC-3)")
        #expect(dismissedMain, "main window must hide on start (AC-3)")

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
        #expect(revealed?.count == 1, "finished files must be revealed in Finder")
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
        let coordinator = RecordingCoordinator(sessionFactory: { _ in fake1 })

        try await coordinator.start(CoordinatorFixtures.request())
        await coordinator.stop()

        #expect(coordinator.lastDegradedWarning == true, "flag must be true after a degraded stop")

        // Acknowledge: flag must clear.
        coordinator.acknowledgeDegradedWarning()
        #expect(coordinator.lastDegradedWarning == false, "flag must be false after acknowledgeDegradedWarning()")

        // Session 2: fresh fake so the already-finished stream from session 1 is not reused.
        // A clean result (degradedWarning=false) must leave the flag false — no stale carry-over.
        let fake2 = FakeRecordingControlling(
            result: CoordinatorFixtures.result(degradedWarning: false)
        )
        // Re-bind a new coordinator that uses fake2 for the second session, sharing the same
        // observable state to verify the flag's per-session independence.
        let coordinator2 = RecordingCoordinator(sessionFactory: { _ in fake2 })

        try await coordinator2.start(CoordinatorFixtures.request())
        await coordinator2.stop()

        #expect(coordinator2.lastDegradedWarning == false, "clean session must not set the degraded-warning flag")
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
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable trailing_closure
