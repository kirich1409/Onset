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
        continuation.yield(DropEvent(reason: .cfrNormalizationDrops, source: .encode, count: 7, detectedAt: pts))
        continuation.finish()

        // Stop finishes the state stream so the collector terminates.
        await monitor.stop()
        let emissions = await stateCollector.value

        #expect(emissions.isEmpty) // never degraded

        let counters = await monitor.snapshot()
        #expect(counters.captureDrops == 4)
        #expect(counters.cfrNormalizationDrops == 7)
        #expect(counters.encoderBackpressureDrops == 0)
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
                reason: .encoderBackpressureDrops, source: .encode, count: 1, detectedAt: detectedAt
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
        let counters = await monitor.snapshot()
        #expect(counters.encoderBackpressureDrops == threshold + 1)
    }

    /// Polls the monitor until at least `atLeast` backpressure drops are recorded, so the test does
    /// not race the observe child task. Bounded so a wiring bug fails fast instead of hanging.
    private func waitForBackpressureCount(_ monitor: DropMonitor, atLeast: Int) async {
        let maxAttempts = 200
        for _ in 0..<maxAttempts {
            if await monitor.snapshot().encoderBackpressureDrops >= atLeast {
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
            reason: .encoderBackpressureDrops, source: .encode, count: threshold + 1, detectedAt: detectedAt
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
    @Test("zero breakdown formats all five fields as zero")
    func allZero_formatsCorrectly() {
        let breakdown = DropBreakdown(
            captureScreen: 0,
            captureCameraVideo: 0,
            captureCameraAudio: 0,
            encode: 0,
            writer: 0
        )
        #expect(
            breakdown.summaryLine ==
                "drop breakdown: capture-screen=0 capture-camera-video=0 capture-camera-audio=0 encode=0 writer=0"
        )
    }

    @Test("non-zero breakdown includes each source value in the correct field")
    func nonZero_includesEachField() {
        let breakdown = DropBreakdown(
            captureScreen: 1,
            captureCameraVideo: 240,
            captureCameraAudio: 3,
            encode: 0,
            writer: 5
        )
        let line = breakdown.summaryLine
        #expect(line.contains("capture-screen=1"))
        #expect(line.contains("capture-camera-video=240"))
        #expect(line.contains("capture-camera-audio=3"))
        #expect(line.contains("encode=0"))
        #expect(line.contains("writer=5"))
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
            reason: .encoderBackpressureDrops, source: .encode, count: 4, detectedAt: pts
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
        #expect(bkd.encode == 4)
        #expect(bkd.writer == 5)
    }

    /// Asserts that `writer` and `encode` drops land in their own buckets, not each other's.
    @Test("writer drop lands in writer bucket, encode drop lands in encode bucket")
    func writerVsEncode_separateBuckets() async {
        let monitor = DropMonitor(windowSeconds: 100.0, threshold: 100)

        let (drops, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        await monitor.observe(drops)

        let pts = CMTime(value: 2000, timescale: 1000)
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: 10, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .encode, count: 7, detectedAt: pts
        ))
        continuation.finish()

        await monitor.stop()

        let bkd = await monitor.breakdownSnapshot()
        #expect(bkd.writer == 10)
        #expect(bkd.encode == 7)
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
        // Distribute drops across all five sources with distinct counts.
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
            reason: .encoderBackpressureDrops, source: .encode, count: 4, detectedAt: pts
        ))
        continuation.yield(DropEvent(
            reason: .encoderBackpressureDrops, source: .writer, count: 5, detectedAt: pts
        ))
        continuation.finish()

        await monitor.stop()

        let counters = await monitor.snapshot()
        let bkd = await monitor.breakdownSnapshot()
        let sourceSum = bkd.captureScreen + bkd.captureCameraVideo + bkd.captureCameraAudio + bkd.encode + bkd.writer
        #expect(
            counters.encoderBackpressureDrops == sourceSum,
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

        let counters = await monitor.snapshot()
        let bkd = await monitor.breakdownSnapshot()
        // captureDrop is counted in captureDrops, NOT encoderBackpressureDrops.
        #expect(counters.captureDrops == 6)
        #expect(counters.encoderBackpressureDrops == 0)
        // Source bucket is incremented independently.
        #expect(bkd.captureCameraVideo == 6)
    }
}
