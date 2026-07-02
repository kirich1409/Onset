// DropMonitorTests.swift
// OnsetTests
//
// Swift Testing suites for DropMonitor (#35).
//
// Two layers, mirroring VideoEncoder's test split:
//   - `BackpressureDegradationWindow` (pure): the core of AC-8. Time values are explicit Double
//     seconds — no clock, no CoreMedia — so threshold/eviction/recovery are deterministic.
//   - `DropMonitor` (actor): wiring + transition emission. Recovery-by-time is driven through the
//     `evaluate(nowSeconds:)` test seam so the actor test never awaits a real clock and cannot flake.
//
// file_length: suites for BackpressureDegradationWindow, DropBreakdown, and DropMonitor live
// together since they share the same test seams and setup patterns. swiftlint:disable file_length
import CoreMedia
@testable import Onset
import Testing

// MARK: - Pure window: threshold

@Suite("BackpressureDegradationWindow — threshold (AC-8)")
struct DegradationWindowThresholdTests {
    // 2-second window, threshold 3 → degraded only when in-window drops > 3 (i.e. ≥ 4).
    private let windowSeconds = 2.0
    private let threshold = 3

    @Test("drops up to threshold do not degrade")
    func atThreshold_notDegraded() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: self.threshold)
        var degraded = false
        for idx in 0..<self.threshold {
            degraded = window.record(atSeconds: 100.0 + Double(idx) * 0.1, count: 1)
        }
        #expect(degraded == false)
        #expect(window.stamps.count == self.threshold)
    }

    @Test("exceeding threshold within the window degrades")
    func exceedThreshold_degraded() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: self.threshold)
        var degraded = false
        // threshold + 1 drops, all within 0.4s → strictly above threshold.
        for idx in 0..<(self.threshold + 1) {
            degraded = window.record(atSeconds: 100.0 + Double(idx) * 0.1, count: 1)
        }
        #expect(degraded == true)
        #expect(window.stamps.count == self.threshold + 1)
    }

    @Test("a single batched event with count > threshold degrades immediately")
    func batchedCount_degrades() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: self.threshold)
        // One DropEvent carrying 5 drops → 5 stamps recorded (count, not events).
        let degraded = window.record(atSeconds: 100.0, count: 5)
        #expect(degraded == true)
        #expect(window.stamps.count == 5)
    }
}

// MARK: - Pure window: historical eviction (AC-8)

@Suite("BackpressureDegradationWindow — historical eviction (AC-8)")
struct DegradationWindowEvictionTests {
    private let windowSeconds = 2.0
    private let threshold = 3

    @Test("a historical drop outside the window does NOT count toward degradation")
    func historicalDropOutsideWindow_notDegraded() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: self.threshold)
        // Three old drops at t=100 (well before the window of the later burst).
        for _ in 0..<3 {
            _ = window.record(atSeconds: 100.0, count: 1)
        }
        // A later burst at t=110: the old drops are > 2s before now → evicted. Only the fresh
        // drops are in-window, and 3 fresh drops is NOT > threshold(3).
        var degraded = false
        for idx in 0..<3 {
            degraded = window.record(atSeconds: 110.0 + Double(idx) * 0.1, count: 1)
        }
        #expect(degraded == false)
        // The three historical stamps were evicted; only the three fresh ones survive.
        #expect(window.stamps.count == 3)
        #expect(window.stamps.allSatisfy { $0 >= 110.0 })
    }

    @Test("an entry exactly on the cutoff is still in-window")
    func entryOnCutoff_inWindow() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: 0)
        _ = window.record(atSeconds: 100.0, count: 1)
        // now = 102 → cutoff = 100. The stamp at exactly 100 is NOT strictly older, so it survives.
        let degraded = window.evaluate(nowSeconds: 102.0)
        #expect(degraded == true) // 1 in-window drop > threshold(0)
        #expect(window.stamps.count == 1)
    }
}

// MARK: - Pure window: recovery (Live)

@Suite("BackpressureDegradationWindow — recovery (Live)")
struct DegradationWindowRecoveryTests {
    private let windowSeconds = 2.0
    private let threshold = 3

    @Test("window recovers via evaluate(now) once the window empties")
    func recoversAfterWindowEmpties() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: self.threshold)
        // Burst at t=100 → degraded.
        for idx in 0..<(self.threshold + 1) {
            _ = window.record(atSeconds: 100.0 + Double(idx) * 0.1, count: 1)
        }
        #expect(window.evaluate(nowSeconds: 100.4) == true)

        // No new drops; advance well past the window → all stamps evicted → recovered.
        let stillDegraded = window.evaluate(nowSeconds: 105.0)
        #expect(stillDegraded == false)
        #expect(window.stamps.isEmpty)
    }

    @Test("partial recovery: only the stale tail of a burst is evicted")
    func partialEviction() {
        var window = BackpressureDegradationWindow(windowSeconds: self.windowSeconds, threshold: 1)
        _ = window.record(atSeconds: 100.0, count: 1)
        _ = window.record(atSeconds: 100.5, count: 1)
        _ = window.record(atSeconds: 103.0, count: 1)
        // now = 103.0 → cutoff = 101.0. The two early stamps (100.0, 100.5) are evicted; only
        // 103.0 survives → 1 in-window drop is NOT > threshold(1).
        let degraded = window.evaluate(nowSeconds: 103.0)
        #expect(degraded == false)
        #expect(window.stamps == [103.0])
    }
}

// MARK: - Actor: counter separation (AC-8)

@Suite("DropMonitor — counter separation (AC-8)")
struct DropMonitorCounterSeparationTests {
    /// Builds a backpressure-irrelevant event stream (capture + CFR drops only) and asserts the
    /// state never leaves `.normal`, while the cumulative counters still grow independently.
    @Test("capture and CFR drops never degrade; counters grow independently")
    func nonBackpressureDrops_stayNormal() async {
        let monitor = DropMonitor(windowSeconds: 2.0, threshold: 0)

        // Collect any state emission. With threshold 0, a SINGLE backpressure drop would degrade —
        // so a degraded emission here would be a counter-routing bug. Capture/CFR must not emit.
        let stateCollector = Task { () -> [RecordingState] in
            var seen: [RecordingState] = []
            for await value in monitor.state {
                seen.append(value)
            }
            return seen
        }

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(reason: .captureDrop, source: .captureCameraVideo, count: 4, detectedAt: pts))
        continuation.yield(DropEvent(reason: .cfrNormalizationDrops, source: .encodeScreen, count: 7, detectedAt: pts))
        continuation.finish()

        // Stop finishes the state stream so the collector terminates.
        await monitor.stop()
        let emissions = await stateCollector.value

        #expect(emissions.isEmpty) // never degraded

        let health = await monitor.snapshot()
        #expect(health.counters.captureDrops == 4)
        #expect(health.counters.cfrNormalizationDrops == 7)
        #expect(health.counters.encoderBackpressureDrops == 0)
    }
}

// MARK: - Actor: transition emission

@Suite("DropMonitor — state transitions")
struct DropMonitorTransitionTests {
    /// Drives `.normal → .degraded → .normal` deterministically: backpressure events cross the
    /// threshold (degraded), then the `evaluate(nowSeconds:)` test seam advances time past the
    /// window (recovery) — no real-clock await.
    @Test("backpressure burst then recovery emits .degraded then .normal")
    func normalDegradedNormal() async {
        // Large window so the actor's real-clock recovery tick (interval = window/4 = 25s) cannot
        // fire during the sub-second test run. Recovery here is driven exclusively through the
        // explicit `evaluate(nowSeconds:)` seam — the burst and the recovery time are synthetic
        // seconds, deterministic regardless of wall-clock.
        let windowSeconds = 100.0
        let threshold = 2
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let stateCollector = Task { () -> [RecordingState] in
            var seen: [RecordingState] = []
            for await value in monitor.state {
                seen.append(value)
            }
            return seen
        }

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // Burst of threshold + 1 backpressure drops near t=100 → degraded transition.
        // timescale 1000 → value N ms == N/1000 s, so value 100_000 == 100.0s.
        let baseMillis: Int64 = 100_000
        for idx in 0..<(threshold + 1) {
            let detectedAt = CMTime(value: baseMillis + Int64(idx) * 10, timescale: 1000)
            continuation.yield(DropEvent(
                reason: .encoderBackpressureDrops, source: .encodeScreen, count: 1, detectedAt: detectedAt
            ))
        }
        continuation.finish()

        // Ensure all yielded events are ingested before we probe recovery: await the observe task
        // draining by reading the counter back to threshold + 1.
        await self.waitForBackpressureCount(monitor, atLeast: threshold + 1)

        // Drive recovery deterministically: jump well past the window (burst at ~100s, window 100s
        // → any now > 200s evicts every stamp).
        await monitor.evaluate(nowSeconds: 300.0)

        await monitor.stop()
        let emissions = await stateCollector.value

        #expect(emissions == [.degraded, .normal])

        // Cumulative counter is unaffected by recovery (never reset).
        let health = await monitor.snapshot()
        #expect(health.counters.encoderBackpressureDrops == threshold + 1)
    }

    /// Polls the monitor until at least `atLeast` backpressure drops are recorded, so the test does
    /// not race the observe child task. Bounded so a wiring bug fails fast instead of hanging.
    private func waitForBackpressureCount(_ monitor: DropMonitor, atLeast: Int) async {
        let maxAttempts = 200
        for _ in 0..<maxAttempts {
            if await monitor.snapshot().counters.encoderBackpressureDrops >= atLeast {
                return
            }
            await Task.yield()
        }
    }

    /// Yields a single `DropEvent` with `count > threshold` and asserts the actor forwards
    /// `event.count` to the sliding window end-to-end — proving the actor passes `count`, not
    /// a hardcoded `1`, to `window.record(count:)`.
    @Test("single batched DropEvent with count > threshold degrades the actor")
    func batchedDropEvent_degradesActor() async {
        let threshold = 3
        let windowSeconds = 100.0
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let stateCollector = Task { () -> [RecordingState] in
            var seen: [RecordingState] = []
            for await value in monitor.state {
                seen.append(value)
            }
            return seen
        }

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // One event carrying count = threshold + 1 — the actor must forward `count` to the window.
        let detectedAt = CMTime(value: 100_000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeScreen, count: threshold + 1, detectedAt: detectedAt
        ))
        continuation.finish()

        await self.waitForBackpressureCount(monitor, atLeast: threshold + 1)

        await monitor.stop()
        let emissions = await stateCollector.value

        // The window must have seen threshold + 1 stamps and emitted .degraded.
        #expect(emissions.contains(.degraded), "actor must transition to .degraded when count > threshold")
    }
}

// MARK: - DropBreakdown: summaryLine (pure)

@Suite("DropBreakdown — summaryLine")
struct DropBreakdownSummaryLineTests {
    @Test("zero breakdown formats all fields as zero")
    func allZero_formatsCorrectly() {
        let breakdown = DropBreakdown(
            captureScreen: 0,
            captureCameraVideo: 0,
            captureCameraAudio: 0,
            encodeScreen: 0,
            encodeCamera: 0,
            bpEncodeScreen: 0,
            bpEncodeCamera: 0,
            writer: 0,
            stabilizeCamera: 0,
            bpStabilizeCamera: 0,
            stabilizationBypassAtSeconds: nil
        )
        #expect(
            breakdown.summaryLine ==
                // swiftlint:disable:next line_length
                "drop breakdown: capture-screen=0 capture-camera-video=0 capture-camera-audio=0 encode-screen=0 encode-camera=0 writer=0 stabilize-camera=0"
        )
    }

    @Test("non-zero breakdown includes each source value in the correct field")
    func nonZero_includesEachField() {
        let breakdown = DropBreakdown(
            captureScreen: 1,
            captureCameraVideo: 240,
            captureCameraAudio: 3,
            encodeScreen: 0,
            encodeCamera: 8,
            bpEncodeScreen: 0,
            bpEncodeCamera: 8,
            writer: 5,
            stabilizeCamera: 21,
            bpStabilizeCamera: 4,
            stabilizationBypassAtSeconds: nil
        )
        let line = breakdown.summaryLine
        #expect(line.contains("capture-screen=1"))
        #expect(line.contains("capture-camera-video=240"))
        #expect(line.contains("capture-camera-audio=3"))
        #expect(line.contains("encode-screen=0"))
        #expect(line.contains("encode-camera=8"))
        #expect(line.contains("writer=5"))
        #expect(line.contains("stabilize-camera=21"))
    }
}

// MARK: - DropMonitor: per-source breakdown accumulation

@Suite("DropMonitor — per-source breakdown accumulation")
struct DropMonitorBreakdownTests {
    /// Feeds one drop of each source through the monitor and asserts each lands in its
    /// correct bucket, independent of the existing reason-counter accounting.
    @Test("one drop per source lands in the correct breakdown bucket")
    func oneDropPerSource_landsInCorrectBucket() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 100)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureScreen, count: 1, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureCameraVideo, count: 2, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureCameraAudio, count: 3, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeScreen, count: 4, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: 5, detectedAt: pts
        ))
        continuation.finish()

        await monitor.stop()

        let bkd = await monitor.breakdownSnapshot()
        #expect(bkd.captureScreen == 1)
        #expect(bkd.captureCameraVideo == 2)
        #expect(bkd.captureCameraAudio == 3)
        #expect(bkd.encodeScreen == 4)
        #expect(bkd.writer == 5)
    }

    /// Asserts that `writer` and `encodeScreen` drops land in their own buckets, not each other's.
    @Test("writer drop lands in writer bucket, encodeScreen drop lands in encodeScreen bucket")
    func writerVsEncode_separateBuckets() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 100)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 2000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: 10, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeScreen, count: 7, detectedAt: pts
        ))
        continuation.finish()

        await monitor.stop()

        let bkd = await monitor.breakdownSnapshot()
        #expect(bkd.writer == 10)
        #expect(bkd.encodeScreen == 7)
        // Other buckets untouched.
        #expect(bkd.captureScreen == 0)
        #expect(bkd.captureCameraVideo == 0)
        #expect(bkd.captureCameraAudio == 0)
    }

    /// Regression guard: the existing `encoderBackpressureDrops` reason counter must equal the
    /// sum of all source buckets when every event carries reason `.encoderBackpressureDrops`.
    /// The source dimension is additive — it must not alter the UI counter total.
    @Test("UI reason counter equals sum of all source buckets (invariant)")
    func reasonCounterEqualsSourceSum_invariant() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 100)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 3000, timescale: 1000)
        // Distribute drops across all six sources with distinct counts.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureScreen, count: 1, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureCameraVideo, count: 2, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .captureCameraAudio, count: 3, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeScreen, count: 4, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeCamera, count: 5, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: 6, detectedAt: pts
        ))
        continuation.finish()

        await monitor.stop()

        let health = await monitor.snapshot()
        let bkd = await monitor.breakdownSnapshot()
        let sourceSum =
            bkd.captureScreen + bkd.captureCameraVideo + bkd.captureCameraAudio +
            bkd.encodeScreen + bkd.encodeCamera + bkd.writer
        #expect(
            health.counters.encoderBackpressureDrops == sourceSum,
            "UI reason counter must equal sum of source buckets — source dimension must not alter UI total"
        )
    }

    /// Asserts that non-backpressure reasons (captureDrop, cfrNormalizationDrops) still
    /// accumulate in the per-source breakdown when tagged, and are not counted in the
    /// encoderBackpressureDrops reason counter.
    @Test("captureDrop tagged .captureCameraVideo increments that bucket, not encoderBackpressure counter")
    func captureDropReason_incrementsSourceBucket_notBackpressureCounter() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 0)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 4000, timescale: 1000)
        // captureDrop from camera video path.
        continuation.yield(DropEvent(reason: .captureDrop, source: .captureCameraVideo, count: 6, detectedAt: pts))
        continuation.finish()

        await monitor.stop()

        let health = await monitor.snapshot()
        let bkd = await monitor.breakdownSnapshot()
        // captureDrop is counted in captureDrops, NOT encoderBackpressureDrops.
        #expect(health.counters.captureDrops == 6)
        #expect(health.counters.encoderBackpressureDrops == 0)
        // Source bucket is incremented independently.
        #expect(bkd.captureCameraVideo == 6)
    }

    /// Guard: screen and camera encoder backpressure drops land in separate `bpEncodeScreen` /
    /// `bpEncodeCamera` breakdown fields, and the totals match what the formatter uses for
    /// per-lane real-loss attribution.
    @Test("encodeScreen and encodeCamera backpressure drops land in separate bpEncode* fields")
    func encodeScreenVsCamera_bpFieldsSplit() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 100)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // Screen encoder: 10 backpressure + 3 CFR-normalization.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeScreen,
            count: 10,
            detectedAt: pts
        ))
        continuation.yield(DropEvent(reason: .cfrNormalizationDrops, source: .encodeScreen, count: 3, detectedAt: pts))
        // Camera encoder: 20 backpressure only.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeCamera,
            count: 20,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let bkd = await monitor.breakdownSnapshot()
        // All-reason totals.
        #expect(bkd.encodeScreen == 13) // 10 bp + 3 cfr
        #expect(bkd.encodeCamera == 20) // 20 bp
        // Backpressure-only subsets — used by the formatter for real-loss attribution.
        #expect(bkd.bpEncodeScreen == 10)
        #expect(bkd.bpEncodeCamera == 20)

        // UI counter reflects both lanes combined (source dimension is additive).
        let health = await monitor.snapshot()
        #expect(health.counters.encoderBackpressureDrops == 30)
        #expect(health.counters.cfrNormalizationDrops == 3)
    }
}

// MARK: - DropMonitorHealthTests

/// Tests for `DropHealthSnapshot` semantics: the `sessionEverDegraded` latch, the
/// `dominantCause` invariant (`.notDegraded` iff `sessionEverDegraded == false`),
/// tie-break order, and the misattribution guard that prevents non-backpressure drops
/// from contributing to `dominantCause`.
@Suite("DropMonitor — health snapshot semantics")
struct DropMonitorHealthTests {
    // Small window and threshold make test data compact without losing coverage.
    private let windowSeconds = 2.0
    private let threshold = 3

    // MARK: Helpers

    /// Polls until `sessionEverDegraded` is set (or gives up after 200 yields to avoid hanging
    /// on a wiring regression). Mirrors `waitForBackpressureCount` in `DropMonitorTransitionTests`.
    private func waitForLatch(_ monitor: DropMonitor) async {
        for _ in 0..<200 {
            if await monitor.snapshot().sessionEverDegraded { return }
            await Task.yield()
        }
    }

    // MARK: Test 1 — sub-threshold backpressure never sets the latch

    /// Backpressure drops that stay under the threshold must not set `sessionEverDegraded` and
    /// must leave `dominantCause` as `.notDegraded` (invariant: cause suppressed when not degraded).
    @Test("sub-threshold backpressure — sessionEverDegraded false, dominantCause .notDegraded")
    func subThresholdBackpressure_noLatch() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // threshold is 3 → count:3 is at-threshold (strict: count > threshold), not crossing.
        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: self.threshold, detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == false)
        #expect(health.dominantCause == .notDegraded)
    }

    // MARK: Test 2 — latch semantics: degraded then recovered → latch stays true

    /// After the burst crosses the threshold and then the window recovers to `.normal`, the latch
    /// `sessionEverDegraded` must remain `true`. This proves the one-way latch behaviour.
    @Test("latch persists after recovery — sessionEverDegraded stays true, dominantCause non-.notDegraded")
    func latch_persistsAfterRecovery() async {
        // Large window: recovery is driven exclusively through `evaluate(nowSeconds:)` so the
        // test cannot flake on the actor's background tick.
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // threshold+1 drops in a tight window → degraded transition, latch set.
        let pts = CMTime(value: 100_000, timescale: 1000) // 100 s
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .writer,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()

        await self.waitForLatch(monitor)

        // Drive recovery: advance synthetic clock well past the 100 s window.
        await monitor.evaluate(nowSeconds: 300.0)
        await monitor.stop()

        let health = await monitor.snapshot()
        // Latch must not reset after recovery.
        #expect(health.sessionEverDegraded == true)
        // dominantCause must remain set (invariant: non-.notDegraded iff sessionEverDegraded).
        #expect(health.dominantCause != .notDegraded)
    }

    // MARK: Test 3 — dominant cause reflects concentrated backpressure source

    /// When all backpressure is concentrated on `.writer`, `dominantCause` must be `.writer`.
    @Test("writer-concentrated backpressure — dominantCause == .writer")
    func writerConcentrated_dominantCauseWriter() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .writer,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.dominantCause == .writer)
    }

    /// When all backpressure is concentrated on `.captureScreen`, `dominantCause` must be `.captureScreen`.
    @Test("captureScreen-concentrated backpressure — dominantCause == .captureScreen")
    func captureScreenConcentrated_dominantCauseCaptureScreen() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .captureScreen,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.dominantCause == .captureScreen)
    }

    // MARK: Test 4 — tie-break order: writer beats encode when counts are equal

    /// When `bpWriter == bpEncode` and both hold the highest count, `.writer` wins because
    /// the tie-break order is writer > encode > captureScreen > captureCameraVideo > captureCameraAudio.
    @Test("tie-break: equal writer and encode counts — dominantCause == .writer (writer beats encode)")
    func tieBreak_writerBeatsEncode() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // Equal counts across writer and encode — threshold+1 each to ensure degradation.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .writer,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeScreen,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.dominantCause == .writer)
    }

    // MARK: Test 5 — misattribution guard

    /// Heavy `.captureDrop` / `.cfrNormalizationDrops` events must never trigger degraded state
    /// and must leave `dominantCause` as `.notDegraded`. These reasons do not increment the
    /// `bp*` backpressure counters — they must not be misattributed as a dominant cause.
    @Test("heavy captureDrop and cfrNormalizationDrops — no degradation, dominantCause .notDegraded")
    func nonBackpressureDrops_noMisattribution() async {
        // threshold:0 means even one backpressure drop would degrade — ensures the test catches
        // any misrouting of captureDrop/CFR events into the bp* counters.
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: 0)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .captureDrop, source: .captureScreen, count: 100, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .cfrNormalizationDrops, source: .encodeScreen, count: 100, detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == false)
        #expect(health.dominantCause == .notDegraded)
    }

    // MARK: Test 6 — sub-threshold bp* > 0 suppresses cause

    /// When backpressure drops accumulate but never cross the threshold, the window never
    /// trips and `dominantCause` must stay `.notDegraded` even though `bp*` counters are non-zero.
    /// This is the invariant enforced by the `sessionEverDegraded` gate in `snapshot()`.
    @Test("sub-threshold bp* > 0 — dominantCause suppressed to .notDegraded (invariant gate)")
    func subThreshold_bpNonZero_causeStillNotDegraded() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // count == threshold: strict check is count > threshold, so latch is NOT set.
        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeScreen,
            count: self.threshold,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        // bp* counter is non-zero, but the window was never tripped.
        #expect(health.counters.encoderBackpressureDrops == self.threshold)
        #expect(health.sessionEverDegraded == false)
        // The invariant gate in snapshot() must suppress cause to .notDegraded.
        #expect(health.dominantCause == .notDegraded)
    }
}

// MARK: - DropHealthSnapshotEquatableTests

/// Round-trip tests for `DropHealthSnapshot.Equatable` — two equal snapshots compare `==`,
/// two snapshots differing in exactly one field compare `!=`.
@Suite("DropHealthSnapshot — Equatable round-trip")
struct DropHealthSnapshotEquatableTests {
    private let baseCounters = DropCounters(
        encoderBackpressureDrops: 10,
        captureDrops: 5,
        cfrNormalizationDrops: 2
    )

    @Test("identical snapshots are equal")
    func identical_areEqual() {
        let lhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .writer)
        let rhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .writer)
        #expect(lhs == rhs)
    }

    @Test("snapshots differing in dominantCause are not equal")
    func differingDominantCause_notEqual() {
        let lhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .writer)
        let rhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .encode)
        #expect(lhs != rhs)
    }

    @Test("snapshots differing in sessionEverDegraded are not equal")
    func differingSessionEverDegraded_notEqual() {
        let lhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .writer)
        let rhs = DropHealthSnapshot(
            counters: baseCounters, sessionEverDegraded: false, dominantCause: .notDegraded
        )
        #expect(lhs != rhs)
    }

    @Test("snapshots differing in a counter field are not equal")
    func differingCounter_notEqual() {
        let otherCounters = DropCounters(
            encoderBackpressureDrops: 99,
            captureDrops: 5,
            cfrNormalizationDrops: 2
        )
        let lhs = DropHealthSnapshot(counters: baseCounters, sessionEverDegraded: true, dominantCause: .writer)
        let rhs = DropHealthSnapshot(counters: otherCounters, sessionEverDegraded: true, dominantCause: .writer)
        #expect(lhs != rhs)
    }
}

// MARK: - DropMonitorCaptureBackpressureTests

/// Tests for issue #100 fix: `.captureBackpressureDrops` must fold into the `captureDrops`
/// counter and must NOT drive the degraded-state window or post-stop alert.
///
/// Verifies:
/// - capture overflow increments `captureDrops` counter (not `encoderBackpressureDrops`)
/// - capture overflow never sets `sessionEverDegraded` latch, even above the backpressure threshold
/// - `degradedWarning` (which delegates to `sessionEverDegraded`) stays `false`
/// - genuine encoder-gate (`encoderBackpressureDrops`) still drives the alert
@Suite("DropMonitor — captureBackpressureDrops counter routing (#100)")
struct DropMonitorCaptureBackpressureTests {
    // Large threshold: capture-overflow drops must NOT cross it, but we send many to be sure.
    private let windowSeconds = 2.0
    private let threshold = 3

    // MARK: Test 1 — capture overflow increments captureDrops, not encoderBackpressureDrops

    /// A `.captureBackpressureDrops` event must increment `captureDrops` and leave
    /// `encoderBackpressureDrops` unchanged.
    @Test("captureBackpressureDrops increments captureDrops counter, not encoderBackpressureDrops")
    func captureBackpressure_incrementsCaptureDrops() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .captureBackpressureDrops, source: .captureScreen, count: 5, detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.counters.captureDrops == 5)
        #expect(health.counters.encoderBackpressureDrops == 0)
        #expect(health.counters.cfrNormalizationDrops == 0)
    }

    // MARK: Test 2 — capture overflow above threshold does NOT set degraded latch

    /// Sending more `.captureBackpressureDrops` than the degraded threshold within the window
    /// must NOT set `sessionEverDegraded` — capture overflow is not encoder/disk pressure.
    @Test("captureBackpressureDrops above threshold does NOT set sessionEverDegraded latch")
    func captureBackpressure_aboveThreshold_noLatch() async {
        // threshold = 3, window = 2 s — send threshold+10 all within window to guarantee a
        // false-positive if the routing bug were reintroduced.
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // threshold + 10 drops: if any were fed to the window, this would degrade.
        continuation.yield(DropEvent(
            reason: .captureBackpressureDrops,
            source: .captureCameraVideo,
            count: self.threshold + 10,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == false)
        #expect(health.dominantCause == .notDegraded)
    }

    // MARK: Test 3 — degradedWarning false on capture overflow (AC-9 alert decoupling)

    /// `RecordingResult.degradedWarning` delegates to `sessionEverDegraded`. This test
    /// builds a `RecordingResult` from a `DropHealthSnapshot` produced by pure capture
    /// overflow and asserts the post-stop alert does not fire.
    @Test("captureBackpressureDrops — degradedWarning false (alert decoupled from capture overflow)")
    func captureBackpressure_degradedWarning_isFalse() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .captureBackpressureDrops,
            source: .captureScreen,
            count: 100,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        // Synthesise a RecordingResult to exercise the exact degradedWarning path.
        let result = RecordingResult.empty(health)
        #expect(result.degradedWarning(threshold: self.threshold) == false)
    }

    // MARK: Test 4 — encoderBackpressureDrops still drives the alert

    /// Regression guard: genuine encoder-gate drops must still set `sessionEverDegraded`
    /// and `degradedWarning` after the routing change.
    @Test("encoderBackpressureDrops above threshold still sets sessionEverDegraded (regression guard)")
    func encoderBackpressure_aboveThreshold_setsLatch() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // threshold+1 in one batch — must cross the window and set the latch.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeScreen,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()

        // Poll until the latch is set (actor processes the event asynchronously).
        for _ in 0..<200 {
            if await monitor.snapshot().sessionEverDegraded { break }
            await Task.yield()
        }
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == true)
        let result = RecordingResult.empty(health)
        #expect(result.degradedWarning(threshold: self.threshold) == true)
    }

    // MARK: Test 5 — mixed: capture overflow + encoder drops; only encoder sets latch

    /// When both reasons arrive, `captureDrops` and `encoderBackpressureDrops` accumulate
    /// independently; the latch is set only when encoder drops cross the threshold.
    @Test("mixed captureBackpressure + encoderBackpressure — counters independent, latch set by encoder only")
    func mixed_captureAndEncoder_countersSeparate() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // Capture overflow: many drops, must NOT degrade.
        continuation.yield(DropEvent(
            reason: .captureBackpressureDrops,
            source: .captureScreen,
            count: 50,
            detectedAt: pts
        ))
        // Encoder drop: exactly threshold+1 → crosses the window.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeScreen,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()

        for _ in 0..<200 {
            if await monitor.snapshot().sessionEverDegraded { break }
            await Task.yield()
        }
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.counters.captureDrops == 50)
        #expect(health.counters.encoderBackpressureDrops == self.threshold + 1)
        // Only encoder drops set the latch.
        #expect(health.sessionEverDegraded == true)
    }
}

// MARK: - encoderHoldDrops never degrades (#200)

/// `.encoderHoldDrops` carries SYNTHETIC catch-up hold frames (repeats of the last real frame),
/// which lose no user content when dropped. These tests assert the routing decision in
/// `DropMonitor.ingest`:
/// - hold drops NEVER set `sessionEverDegraded`, even far above the degraded threshold;
/// - hold drops NEVER leak into the user-facing `DropCounters` (`encoderBackpressureDrops`,
///   `captureDrops`, `cfrNormalizationDrops`);
/// - hold drops STILL appear in the per-source diagnostic breakdown (`encodeScreen` bucket);
/// - genuine `.encoderBackpressureDrops` still drives the alert (no over-suppression).
@Suite("DropMonitor — encoderHoldDrops never degrades (#200)")
struct DropMonitorHoldDropsTests {
    private let windowSeconds = 2.0
    private let threshold = 3

    // MARK: Test 1 — hold drops far above threshold never latch, never inflate user counters

    /// A burst of `.encoderHoldDrops` far exceeding the degraded threshold within the window must
    /// NOT set `sessionEverDegraded` and must NOT increment any `DropCounters` field — while still
    /// landing in the `encodeScreen` diagnostic bucket. Under the OLD code these holds carried
    /// `.encoderBackpressureDrops` and would have latched degraded and inflated the user count.
    @Test("encoderHoldDrops above threshold — no latch, user counters zero, visible in breakdown")
    func holdDrops_aboveThreshold_neverDegradesNorInflates() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // A whole catch-up batch worth of holds — far past threshold. If any fed the window, this
        // would degrade; if any landed on encoderBackpressureDrops, the user count would inflate.
        continuation.yield(DropEvent(
            reason: .encoderHoldDrops,
            source: .encodeScreen,
            count: self.threshold + 50,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        // Never degraded — the one-way latch stays clear.
        #expect(health.sessionEverDegraded == false)
        #expect(health.dominantCause == .notDegraded)
        // User-facing dropped-frames counters are NOT inflated by synthetic holds.
        #expect(health.counters.encoderBackpressureDrops == 0)
        #expect(health.counters.captureDrops == 0)
        #expect(health.counters.cfrNormalizationDrops == 0)
        // The post-stop warning must not fire from hold drops alone.
        let result = RecordingResult.empty(health)
        #expect(result.degradedWarning(threshold: self.threshold) == false)

        // But the holds REMAIN observable in the per-source diagnostic breakdown (encodeScreen bucket).
        let breakdown = await monitor.breakdownSnapshot()
        #expect(breakdown.encodeScreen == self.threshold + 50)
    }

    // MARK: Test 2 — real backpressure still degrades alongside hold drops (no over-suppression)

    /// Hold drops and genuine encoder-backpressure drops arrive together: the holds stay inert
    /// while the real-content drops still cross the threshold and set the latch. Proves the fix
    /// did not over-suppress the existing degraded behavior — only synthetic holds are spared.
    @Test("encoderHoldDrops inert while real encoderBackpressureDrops still sets the latch")
    func holdDrops_doNotSuppressRealBackpressureDegradation() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        // Many synthetic holds — must NOT touch the window.
        continuation.yield(DropEvent(
            reason: .encoderHoldDrops, source: .encodeScreen, count: 50, detectedAt: pts
        ))
        // Genuine real-content backpressure: threshold+1 → crosses the window, sets the latch.
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encodeScreen, count: self.threshold + 1, detectedAt: pts
        ))
        continuation.finish()

        for _ in 0..<200 {
            if await monitor.snapshot().sessionEverDegraded { break }
            await Task.yield()
        }
        await monitor.stop()

        let health = await monitor.snapshot()
        // Real backpressure still degrades — the fix is not over-suppressing.
        #expect(health.sessionEverDegraded == true)
        // Only the real-content drops are reflected in the user-facing counter; holds excluded.
        #expect(health.counters.encoderBackpressureDrops == self.threshold + 1)
        let result = RecordingResult.empty(health)
        #expect(result.degradedWarning(threshold: self.threshold) == true)
    }
}

// MARK: - stop() drains buffered tail (#202)

/// Regression guard for #202: `stop()` must DRAIN the observe tasks (await without cancelling),
/// not cancel them. Cancelling truncates the `for await event in drops` iteration immediately,
/// discarding any `DropEvent` still buffered in the source stream — so the final
/// `breakdownSnapshot()` / `snapshot()` would under-count the tail.
///
/// ## Discrimination caveat (why this is a contract test, not a race-reproducer)
///
/// This asserts the contract — feed N events, finish, `stop()`, ALL N counted — which is
/// deterministic under drain-only for any N. It does NOT deterministically reproduce the
/// cancel-first bug in-process: `stop()` begins with `await tickTask?.value`, and that suspension
/// hands the actor away long enough for the observe task to drain the entire (unbounded-buffered)
/// stream of trivial `ingest` calls and end naturally — so the subsequent `task.cancel()` is a
/// no-op even under the old code. Empirically verified: a temporary cancel-first revert still
/// counted all N at N = 50_000 (the in-process race is un-loseable for trivial ingests through the
/// public API). The bug bites in production where a real burst cannot drain inside that window.
/// Keeping the contract assertion small and fast is the right trade — it stays green against future
/// code and never flakes; adding a production `ingest` seam purely to lose the race would violate
/// minimal-diff.
@Suite("DropMonitor — stop() drains buffered tail (#202)", .timeLimit(.minutes(1)))
struct DropMonitorStopDrainTests {
    private let windowSeconds = 2.0
    private let threshold = 3

    /// All buffered diagnostic-breakdown drops are counted after `stop()` — none lost to truncation.
    @Test("stop drains the full buffered tail into the breakdown counters")
    func stop_drainsBufferedTail_breakdownCountsAll() async {
        let monitor = DropMonitor(windowSeconds: self.windowSeconds, threshold: self.threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // Buffer the events, then finish the stream. Drain-only stop() must ingest every one before
        // reading the counters (see the suite caveat on why this is a contract, not a race repro).
        let eventCount = 64
        let pts = CMTime(value: 1000, timescale: 1000)
        for _ in 0..<eventCount {
            continuation.yield(DropEvent(
                reason: .captureDrop, source: .captureScreen, count: 1, detectedAt: pts
            ))
        }
        continuation.finish()

        // Drain-only stop: must read every buffered event before snapshotting the counters.
        await monitor.stop()

        // Diagnostic breakdown counts ALL events — the drained tail is never lost.
        let breakdown = await monitor.breakdownSnapshot()
        #expect(breakdown.captureScreen == eventCount)

        // The cumulative reason counter must also reflect the full tail.
        let health = await monitor.snapshot()
        #expect(health.counters.captureDrops == eventCount)
    }

    /// `stop()` completes (does not hang) when the observed stream is finished — the drain-only
    /// precondition. If this test returns at all, drain-only terminated; a regression that left a
    /// stream unfinished here would hang and trip the suite time limit.
    @Test("stop completes without hanging when the observed stream is finished")
    func stop_completes_whenStreamFinished() async {
        let monitor = DropMonitor(windowSeconds: self.windowSeconds, threshold: self.threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)
        continuation.finish()

        await monitor.stop()
        // Reaching here proves stop() returned — no deadlock on a finished stream.
    }

    /// `cancelObservation()` (failed-start path) terminates even when the observed stream is NOT
    /// finished. Drain-only would hang here; cancellation ends the observe task regardless. This is
    /// the deadlock guard for `teardownAfterFailedStart()`.
    @Test("cancelObservation completes without hanging when the observed stream stays open")
    func cancelObservation_completes_whenStreamOpen() async {
        let monitor = DropMonitor(windowSeconds: self.windowSeconds, threshold: self.threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        // Deliberately do NOT finish the stream — mirrors a writer.drops left open on a failed start.
        await monitor.cancelObservation()
        // Reaching here proves cancelObservation() returned despite the open stream.

        // Keep the continuation alive past the assertion so the stream is not finished by deinit
        // before cancelObservation() ran.
        continuation.finish()
    }
}

// MARK: - NonisolatedInequalityRegressionTests (#187)

/// Regression for #187: `!=` on the pipeline value types must be callable from a `nonisolated`
/// context. The default `Equatable` `!=` extension binds the *conformance*, which under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `InferIsolatedConformances` is inferred
/// `@MainActor` when declared in a bare `extension X: Equatable`. Moving the conformance onto the
/// `nonisolated` type decl keeps it nonisolated so `!=` compiles off the main actor.
///
/// `compareOffMainActor` is a free `nonisolated` function — its body is exactly the call site that
/// failed to compile before the fix. The assertions inside are `Bool` checks (no `#expect` in the
/// nonisolated helper, since the macro expands main-actor-isolated); the test merely calls it.
nonisolated private func compareOffMainActor() -> Bool {
    let firstDropCount = 1
    let secondDropCount = 2
    let snapshotA = DropHealthSnapshot(
        counters: DropCounters(encoderBackpressureDrops: firstDropCount, captureDrops: 0, cfrNormalizationDrops: 0),
        sessionEverDegraded: true,
        dominantCause: .writer
    )
    let snapshotB = DropHealthSnapshot(
        counters: DropCounters(encoderBackpressureDrops: secondDropCount, captureDrops: 0, cfrNormalizationDrops: 0),
        sessionEverDegraded: true,
        dominantCause: .encode
    )

    // Each `!=` below would fail to compile from this nonisolated context before #187.
    let snapshotsDiffer = snapshotA != snapshotB
    let causesDiffer = DropCause.writer != DropCause.encode
    let sourcesDiffer = DropSource.captureScreen != DropSource.encodeScreen
    return snapshotsDiffer && causesDiffer && sourcesDiffer
}

@Suite("Pipeline value types — != from nonisolated context (#187)")
struct NonisolatedInequalityRegressionTests {
    /// Compiling + passing proves the conformances are nonisolated and `!=` is reachable off the
    /// main actor — the exact construct that failed to compile before the fix.
    @Test("!= on DropHealthSnapshot / DropCause / DropSource works from a nonisolated function")
    func inequality_compilesAndHolds_fromNonisolatedContext() {
        #expect(compareOffMainActor())
    }
}

// MARK: - Stabilization-stage routing (#297)

@Suite("DropMonitor — stabilization stage routing (#297)")
struct DropMonitorStabilizationTests {
    private let windowSeconds = 2.0
    private let threshold = 3

    /// AC-4 diagnostic-only contract: `.stabilizationDrops` must never trip the degraded window
    /// (even at threshold 0), never set the latch, and never leak into `DropCounters` — the stage
    /// total is visible only through the per-source breakdown.
    @Test("stabilizationDrops are diagnostic-only: no degradation, no counter leak, breakdown only")
    func stabilizationDrops_diagnosticOnly() async {
        // threshold:0 means a single backpressure drop would degrade — catches any misrouting
        // of .stabilizationDrops into the window.
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: 0)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .stabilizationDrops, source: .stabilizeCamera, count: 100, detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == false)
        #expect(health.dominantCause == .notDegraded)
        // DropCounters must not change (#297: counters/snapshot shape untouched).
        #expect(health.counters.encoderBackpressureDrops == 0)
        #expect(health.counters.captureDrops == 0)
        #expect(health.counters.cfrNormalizationDrops == 0)

        let bkd = await monitor.breakdownSnapshot()
        #expect(bkd.stabilizeCamera == 100)
        #expect(bkd.bpStabilizeCamera == 0)
    }

    /// The stage's OUTPUT overflow (reason `.encoderBackpressureDrops`, source `.stabilizeCamera`)
    /// is real content loss: it feeds the degraded window and resolves the dominant cause to
    /// `.stabilizeCamera`, and lands in both the total and the bp-only breakdown buckets.
    @Test("stage output backpressure degrades and resolves dominantCause == .stabilizeCamera")
    func stageOutputBackpressure_feedsWindowAndDominantCause() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .stabilizeCamera,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.sessionEverDegraded == true)
        #expect(health.dominantCause == .stabilizeCamera)
        #expect(health.counters.encoderBackpressureDrops == self.threshold + 1)

        let bkd = await monitor.breakdownSnapshot()
        #expect(bkd.stabilizeCamera == self.threshold + 1)
        #expect(bkd.bpStabilizeCamera == self.threshold + 1)
    }

    /// Tie-break position: encode outranks stabilizeCamera at equal counts
    /// (writer > encode > stabilizeCamera > captureScreen > …).
    @Test("tie-break: equal encode and stabilizeCamera counts — encode wins")
    func tieBreak_encodeBeatsStabilizeCamera() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 1000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .encodeCamera,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops,
            source: .stabilizeCamera,
            count: self.threshold + 1,
            detectedAt: pts
        ))
        continuation.finish()
        await monitor.stop()

        let health = await monitor.snapshot()
        #expect(health.dominantCause == .encode)
    }

    /// `noteStabilizationBypass(atSeconds:)` surfaces the transition time on the breakdown;
    /// a `nil` note is ignored (never bypassed).
    @Test("noteStabilizationBypass surfaces on the breakdown snapshot; nil is ignored")
    func noteBypass_surfacesOnBreakdown() async {
        let monitor = DropMonitor(windowSeconds: windowSeconds, threshold: threshold)

        await monitor.noteStabilizationBypass(atSeconds: nil)
        var bkd = await monitor.breakdownSnapshot()
        #expect(bkd.stabilizationBypassAtSeconds == nil)

        await monitor.noteStabilizationBypass(atSeconds: 42.5)
        bkd = await monitor.breakdownSnapshot()
        #expect(bkd.stabilizationBypassAtSeconds == 42.5)
    }
}
