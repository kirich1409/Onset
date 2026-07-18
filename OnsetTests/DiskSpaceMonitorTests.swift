import Foundation
@testable import Onset
import Testing

// MARK: - Helpers

/// Builds a `DiskThresholds` fixture with small, hand-checkable numbers — mirrors
/// `DiskSpaceEstimatorTests.makeThresholds` (T-3) so the byte-floor crossings below are obvious
/// by inspection.
private func makeThresholds(
    systemWarnBytes: Int64 = 5_000_000,
    systemStopBytes: Int64 = 1_000_000,
    outputWarnBytes: Int64 = 1000,
    outputStopBytes: Int64 = 200,
    outputWarnEtaSeconds: Double = 600,
    outputStopEtaSeconds: Double = 120,
    ewmaTimeConstantSeconds: Double = 16,
    readEverySeconds: Double = 4,
    warmupSeconds: Double = 16,
    hysteresisReleaseBytes: Int64 = 100,
    deescalationDebounceSeconds: Double = 8
)
-> DiskThresholds {
    DiskThresholds(
        systemWarnBytes: systemWarnBytes,
        systemStopBytes: systemStopBytes,
        outputWarnBytes: outputWarnBytes,
        outputStopBytes: outputStopBytes,
        outputWarnEtaSeconds: outputWarnEtaSeconds,
        outputStopEtaSeconds: outputStopEtaSeconds,
        ewmaTimeConstantSeconds: ewmaTimeConstantSeconds,
        readEverySeconds: readEverySeconds,
        warmupSeconds: warmupSeconds,
        hysteresisReleaseBytes: hysteresisReleaseBytes,
        deescalationDebounceSeconds: deescalationDebounceSeconds
    )
}

/// Builds a `RecordingConfiguration` fixture identical to `mvpDefault` except for
/// `diskThresholds` — same field-order-must-match pattern already used by
/// `RecordingSessionTests` for other per-test overrides.
private func makeConfiguration(diskThresholds: DiskThresholds) -> RecordingConfiguration {
    let mvp = RecordingConfiguration.mvpDefault
    return RecordingConfiguration(
        container: mvp.container,
        codec: mvp.codec,
        sampleEntry: mvp.sampleEntry,
        profileLevel: mvp.profileLevel,
        colorPrimaries: mvp.colorPrimaries,
        transferFunction: mvp.transferFunction,
        yCbCrMatrix: mvp.yCbCrMatrix,
        bitDepth: mvp.bitDepth,
        maxScreenFps: mvp.maxScreenFps,
        minCameraFps: mvp.minCameraFps,
        cameraMirror: mvp.cameraMirror,
        bitrateTable: mvp.bitrateTable,
        dataRateLimitsPeakMultiplier: mvp.dataRateLimitsPeakMultiplier,
        keyFrameIntervalSeconds: mvp.keyFrameIntervalSeconds,
        allowFrameReordering: mvp.allowFrameReordering,
        pixelFormatPreference: mvp.pixelFormatPreference,
        audioSampleRate: mvp.audioSampleRate,
        audioChannelCount: mvp.audioChannelCount,
        audioBitrate: mvp.audioBitrate,
        movieFragmentInterval: mvp.movieFragmentInterval,
        degradedBackpressureThreshold: mvp.degradedBackpressureThreshold,
        degradedWindowSeconds: mvp.degradedWindowSeconds,
        postStopDropWarningThreshold: mvp.postStopDropWarningThreshold,
        budgetCap: mvp.budgetCap,
        diskThresholds: diskThresholds,
        baseOutputDirectory: mvp.baseOutputDirectory
    )
}

/// Default poll deadline for `eventually(timeoutMs:_:)`.
private let defaultEventuallyTimeoutMs = 2000
/// Poll interval for `eventually(timeoutMs:_:)` — short enough to keep tests fast, real enough
/// to not busy-spin the run loop.
private let eventuallyPollIntervalNanoseconds: UInt64 = 2_000_000
/// Milliseconds-per-second conversion factor for `eventually(timeoutMs:_:)`'s deadline math.
private let millisecondsPerSecond = 1000.0

/// Polls `condition` (evaluated on `MainActor`, matching `DiskSpaceMonitor`) until it becomes
/// `true` or `timeoutMs` elapses — never a fixed sleep. Used to observe the completion of a
/// `DiskSpaceMonitor.tickRefresh` spawned `Task` without exposing the task handle itself.
/// `condition` is `async` so callers can poll actor-isolated state (e.g. `provider.callCount`)
/// as well as plain `MainActor` state (`monitor.currentVerdict`).
@MainActor
private func eventually(timeoutMs: Int = defaultEventuallyTimeoutMs, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / millisecondsPerSecond)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: eventuallyPollIntervalNanoseconds)
    }
    return await condition()
}

private let sampleOutputURL = URL(fileURLWithPath: "/tmp/OnsetDiskSpaceMonitorTests/output.mp4")

/// Free bytes on the (never-tripped) system volume for tests that only exercise the output
/// volume's byte-floor thresholds.
private let plentifulSystemFreeBytes: Int64 = 5_000_000_000

// MARK: - AC-2/3/4: none → warning → critical transitions

@MainActor
@Suite("DiskSpaceMonitor — verdict transitions")
struct DiskSpaceMonitorTransitionTests {
    @Test("Decreasing output capacity transitions none → warning → critical at spec thresholds")
    func transitions_noneToWarningToCritical() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        await provider.configure(outputFreeBytes: 5000, systemFreeBytes: plentifulSystemFreeBytes)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .none })

        clock.advance(by: 4)
        await provider.setOutputFreeBytes(900)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .warning(.outputFree) })

        clock.advance(by: 4)
        await provider.setOutputFreeBytes(150)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .critical(.outputFree) })
    }

    @Test("A read failure (nil output free bytes) preserves the last-good verdict")
    func nilRead_preservesLastGoodVerdict() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        await provider.configure(outputFreeBytes: 900, systemFreeBytes: plentifulSystemFreeBytes)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .warning(.outputFree) })

        clock.advance(by: 4)
        await provider.setOutputFreeBytes(nil)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        // `refreshInFlight` clearing (the `defer`) is a real signal that `apply(snapshot:)` has
        // already run and decided to skip the nil read — not a fixed sleep hoping it finished.
        #expect(await eventually { !monitor.refreshInFlight })
        #expect(await provider.callCount == 2)
        #expect(monitor.currentVerdict == .warning(.outputFree))
    }
}

// MARK: - Concurrency: single-flight, generation, defer-unwedge

@MainActor
@Suite("DiskSpaceMonitor — concurrency")
struct DiskSpaceMonitorConcurrencyTests {
    @Test("A second tickRefresh while one is in flight does not spawn a second provider read")
    func overlappingSlowRefreshes_singleFlight() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        // A warning-level reading: gives the eventual apply an observable effect distinct from
        // the monitor's initial `.none` state. Delay is long enough to overlap two ticks.
        await provider.configure(
            outputFreeBytes: 900,
            systemFreeBytes: plentifulSystemFreeBytes,
            delayNanoseconds: 150_000_000
        )

        monitor.tickRefresh(outputURL: sampleOutputURL)
        // `refreshInFlight` is set synchronously (before the read `Task` is even spawned), so
        // this is a deterministic proof the guard is armed — no race with the provider's task.
        #expect(monitor.refreshInFlight)
        // Immediately try again (well past readEvery) while the first refresh is still in
        // flight — the single-flight guard must reject this synchronously, without spawning a
        // second provider read.
        clock.advance(by: 100)
        monitor.tickRefresh(outputURL: sampleOutputURL)

        // Let the one in-flight refresh resolve and apply, THEN check the call count — checking
        // it earlier would race the provider's own `Task` scheduling.
        #expect(await eventually(timeoutMs: 1000) { monitor.currentVerdict == .warning(.outputFree) })
        #expect(await provider.callCount == 1)

        // The window was not corrupted by a phantom second sample: the monitor still throttles
        // and issues exactly one further read once readEvery has elapsed again.
        clock.advance(by: 4)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { await provider.callCount == 2 })
    }

    @Test("A slow refresh started before reset() is dropped by generation mismatch")
    func preResetSlowRefresh_droppedByGenerationMismatch() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        // A near-full reading that WOULD be critical if applied.
        await provider.configure(
            outputFreeBytes: 50,
            systemFreeBytes: plentifulSystemFreeBytes,
            delayNanoseconds: 150_000_000
        )

        monitor.tickRefresh(outputURL: sampleOutputURL)
        // New session starts while the stale-session refresh is still in flight.
        monitor.reset()
        #expect(monitor.currentVerdict == .none)

        // Wait for the stale refresh's `defer` to actually fire (real condition, not a fixed
        // sleep hoping the delay elapsed).
        #expect(await eventually(timeoutMs: 1000) { !monitor.refreshInFlight })

        // The stale near-full capacity must NOT have contaminated the new session's verdict.
        #expect(monitor.currentVerdict == .none)
    }

    @Test("reset() bumps state; a subsequent read after the stale refresh resolves is applied fresh")
    func reset_clearsRollingStateForNewSession() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        await provider.configure(outputFreeBytes: 150, systemFreeBytes: plentifulSystemFreeBytes) // critical
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .critical(.outputFree) })

        monitor.reset()
        #expect(monitor.currentVerdict == .none)

        // A fresh, healthy reading after reset is applied normally — proves the smoothing
        // window/one-shot state were actually cleared, not just the verdict field.
        clock.advance(by: 4)
        await provider.setOutputFreeBytes(5000)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .none })
    }

    @Test("refreshInFlight is unwedged by the defer even when reset() races the in-flight refresh")
    func deferUnwedge_futureRefreshesResumeAfterResetMidFlight() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        await provider.configure(
            outputFreeBytes: 5000,
            systemFreeBytes: plentifulSystemFreeBytes,
            delayNanoseconds: 150_000_000
        )

        monitor.tickRefresh(outputURL: sampleOutputURL)
        // `refreshInFlight` is set synchronously (before the read `Task` is spawned) — a
        // deterministic proof the guard is armed, no race with the provider's task scheduling.
        #expect(monitor.refreshInFlight)
        monitor.reset() // races the in-flight refresh; must not permanently wedge the guard

        // A tickRefresh issued immediately still sees refreshInFlight == true (the defer has not
        // fired yet) and is correctly rejected synchronously — no second read spawned yet.
        clock.advance(by: 100)
        monitor.tickRefresh(outputURL: sampleOutputURL)

        // Once the original refresh's `defer` actually fires, refreshInFlight clears — and only
        // then is `callCount` settled enough to check (checking earlier would race the
        // provider's task scheduling).
        #expect(await eventually(timeoutMs: 1000) { !monitor.refreshInFlight })
        #expect(await provider.callCount == 1)

        // ...and a NEW tickRefresh call resumes issuing reads — no permanent wedge.
        clock.advance(by: 4)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { await provider.callCount == 2 })
    }
}

// MARK: - Perf: readEvery-throttle, Equatable-guard

@MainActor
@Suite("DiskSpaceMonitor — cadence and write discipline")
struct DiskSpaceMonitorCadenceTests {
    @Test("tickRefresh called every 1s with readEvery=4s issues exactly one read per 4 ticks")
    func tickRefresh_throttlesToReadEveryNotOneHertz() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds(readEverySeconds: 4)),
            clock: clock
        )
        await provider.configure(outputFreeBytes: 5000, systemFreeBytes: plentifulSystemFreeBytes)

        // Tick 0 (first-ever call always fires — no `lastReadAt` to throttle against yet).
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { await provider.callCount == 1 })

        // Ticks at +1s, +2s, +3s: readEvery (4s) has not elapsed — no new read.
        let throttledTickCount = 3
        for _ in 0..<throttledTickCount {
            clock.advance(by: 1)
            monitor.tickRefresh(outputURL: sampleOutputURL)
        }
        #expect(await provider.callCount == 1)

        // Tick at +4s: readEvery has elapsed — exactly one more read.
        clock.advance(by: 1)
        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { await provider.callCount == 2 })
    }

    @Test("A stable verdict across refreshes is written at most once (Equatable-guard)")
    func stableVerdict_writtenAtMostOnce() async {
        let provider = FakeDiskSpaceProvider()
        let clock = FakeMonotonicClock()
        let monitor = DiskSpaceMonitor(
            provider: provider,
            configuration: makeConfiguration(diskThresholds: makeThresholds()),
            clock: clock
        )
        // A steady warning-level reading: the FIRST refresh changes the cached verdict away from
        // the initial `.none` (one legitimate write); every refresh after that reports the SAME
        // verdict and must not write again.
        await provider.configure(outputFreeBytes: 900, systemFreeBytes: plentifulSystemFreeBytes)

        monitor.tickRefresh(outputURL: sampleOutputURL)
        #expect(await eventually { monitor.currentVerdict == .warning(.outputFree) })
        #expect(monitor.verdictAssignmentCount == 1)

        let additionalTicks = 3
        for tick in 1...additionalTicks {
            clock.advance(by: 4)
            monitor.tickRefresh(outputURL: sampleOutputURL)
            let expectedCallCount = tick + 1
            #expect(await eventually { await provider.callCount == expectedCallCount })
        }

        #expect(monitor.currentVerdict == .warning(.outputFree))
        #expect(monitor.verdictAssignmentCount == 1)
    }
}
