// StabilizationSmootherTests.swift
// OnsetTests
//
// Scope: L2 suites for the pure decision core of the camera-stabilization stage (#297) —
// StabilizationSmoother (lock-with-slow-recenter + bypass ramp), StabilizationWarmUp
// (cadence-driven estScale choice), StabilizationOverloadDetector (bypass trigger 1), and
// StabilizationLatencyAggregator (AC-8 report line). Pure value types, synthetic numbers,
// no hardware, no clock.

@testable import Onset
import Testing

// MARK: - Smoother

@Suite("StabilizationSmoother — lock-with-slow-recenter")
struct StabilizationSmootherTests {
    @Test("Single shift +Δ produces correction ≈ −Δ (sign contract at the smoother level)")
    func singleShift_correctionIsNegatedShift() {
        var smoother = StabilizationSmoother()
        let correction = smoother.ingest(shift: StabilizationVector(deltaX: 2.0, deltaY: -1.0))
        // ref moved at most maxRefStep toward cum, so correction = ref − cum ≈ −shift.
        // 1e-9 slack: 0.01 is not exactly representable in binary floating point, so the
        // residual can exceed the literal by a few ULPs (observed 0.010000000000000009).
        #expect(abs(correction.deltaX - -2.0) <= StabilizationTuning.maxRefStep + 1e-9)
        #expect(abs(correction.deltaY - 1.0) <= StabilizationTuning.maxRefStep + 1e-9)
        #expect(correction.deltaX < 0)
        #expect(correction.deltaY > 0)
    }

    @Test("Rate limit: a burst cannot drag the reference more than maxRefStep per frame")
    func burst_referenceIsRateLimited() {
        var smoother = StabilizationSmoother()
        // A huge one-frame spike: alpha·(cum − ref) = 0.05·10 = 0.5 ≫ maxRefStep.
        _ = smoother.ingest(shift: StabilizationVector(deltaX: 10.0, deltaY: 0))
        #expect(smoother.ref.deltaX == StabilizationTuning.maxRefStep)
        // Second frame with zero shift: the reference keeps crawling with the same clamp.
        _ = smoother.ingest(shift: .zero)
        #expect(smoother.ref.deltaX == 2 * StabilizationTuning.maxRefStep)
    }

    @Test("Recenter: after a step offset the correction decays by ≤ maxRefStep per frame")
    func stepOffset_slowRecenter() {
        var smoother = StabilizationSmoother()
        var correction = smoother.ingest(shift: StabilizationVector(deltaX: 1.0, deltaY: 0))
        let initial = correction.deltaX
        // 100 zero-shift frames: |correction| shrinks monotonically, one rate-limited step each.
        var previous = initial
        for _ in 0..<100 {
            correction = smoother.ingest(shift: .zero)
            let stepMagnitude = abs(correction.deltaX - previous)
            #expect(stepMagnitude <= StabilizationTuning.maxRefStep + 1e-12)
            #expect(abs(correction.deltaX) <= abs(previous))
            previous = correction.deltaX
        }
        // 100 × 0.01 = 1.0 → the offset is fully recentered by now (clamped at cum).
        #expect(abs(correction.deltaX) <= abs(initial))
    }

    @Test("Slow real drift passes through the rate limit with small steady-state lag")
    func slowDrift_smallResidual() {
        var smoother = StabilizationSmoother()
        var correction = StabilizationVector.zero
        // Real measured drift ≈ 0.001 px/frame — an order below the rate limit.
        for _ in 0..<1000 {
            correction = smoother.ingest(shift: StabilizationVector(deltaX: 0.001, deltaY: 0))
        }
        // Steady-state lag e solves alpha·e = rate → e = 0.02; correction ≈ −e.
        #expect(abs(correction.deltaX) < 0.05)
    }

    @Test("Freeze accessor: correction without ingest equals ref − cum")
    func correctionAccessor_matchesState() {
        var smoother = StabilizationSmoother()
        let ingested = smoother.ingest(shift: StabilizationVector(deltaX: 3.0, deltaY: -2.0))
        // The freeze path re-reads the same value without feeding a shift.
        #expect(smoother.correction == ingested)
    }

    @Test("Bypass ramp moves each axis toward zero by ≤ step and stops exactly at zero")
    func ramp_reachesZeroWithoutOvershoot() {
        var current = StabilizationVector(deltaX: 0.35, deltaY: -0.25)
        var steps = 0
        while current != .zero, steps < 10 {
            let next = StabilizationSmoother.ramp(current)
            #expect(abs(next.deltaX - current.deltaX) <= StabilizationTuning.bypassRampStepPx + 1e-12)
            #expect(abs(next.deltaY - current.deltaY) <= StabilizationTuning.bypassRampStepPx + 1e-12)
            #expect(abs(next.deltaX) <= abs(current.deltaX))
            #expect(abs(next.deltaY) <= abs(current.deltaY))
            current = next
            steps += 1
        }
        // 0.35 / 0.1 → 4 steps on the slower axis; no oscillation past zero.
        #expect(current == .zero)
        #expect(steps == 4)
    }

    @Test("Vector clamp bounds each axis independently")
    func vectorClamp_perAxis() {
        let clamped = StabilizationVector(deltaX: 20.0, deltaY: -3.0).clamped(to: 5.0)
        #expect(clamped == StabilizationVector(deltaX: 5.0, deltaY: -3.0))
    }
}

// MARK: - Warm-up

@Suite("StabilizationWarmUp — cadence-driven estScale choice")
struct StabilizationWarmUpTests {
    /// Feeds `count` frames with a fixed inter-frame interval; returns the scale decision.
    private func runWarmUp(frameCount: Int, intervalSeconds: Double) -> Int? {
        var warmUp = StabilizationWarmUp(frameCount: frameCount)
        var decision: Int?
        for index in 0..<frameCount {
            decision = warmUp.record(ptsSeconds: Double(index) * intervalSeconds)
        }
        return decision
    }

    @Test("Slow cadence (50 ms median ≥ 40 ms) chooses the 3× scale on the final warm-up frame")
    func slowCadence_choosesHighScale() {
        #expect(self.runWarmUp(frameCount: 60, intervalSeconds: 0.050) == 3)
    }

    @Test("Honest 30 fps (33 ms median < 40 ms) chooses the 2× scale")
    func fastCadence_choosesLowScale() {
        #expect(self.runWarmUp(frameCount: 60, intervalSeconds: 0.0333) == 2)
    }

    @Test("Decision fires exactly once — on the completing frame, nil before and after")
    func decision_firesExactlyOnce() {
        var warmUp = StabilizationWarmUp(frameCount: 3)
        #expect(warmUp.record(ptsSeconds: 0.00) == nil)
        #expect(warmUp.record(ptsSeconds: 0.05) == nil)
        #expect(warmUp.record(ptsSeconds: 0.10) == 3)
        #expect(warmUp.isComplete)
        // Post-completion frames are ignored (the scale is fixed for the session).
        #expect(warmUp.record(ptsSeconds: 0.15) == nil)
    }

    @Test("Degenerate warm-up with no measurable interval falls back to the conservative 2×")
    func degenerateWarmUp_fallsBackToLowScale() {
        var warmUp = StabilizationWarmUp(frameCount: 1)
        #expect(warmUp.record(ptsSeconds: 0.0) == 2)
    }

    @Test("Median is robust to a latency outlier in the interval series")
    func median_ignoresOutlier() {
        var warmUp = StabilizationWarmUp(frameCount: 5)
        // Intervals: 20, 20, 250(!), 20 ms → median 20 ms → low scale despite the spike.
        var decision: Int?
        for pts in [0.000, 0.020, 0.040, 0.290, 0.310] {
            decision = warmUp.record(ptsSeconds: pts)
        }
        #expect(decision == 2)
    }
}

// MARK: - Overload detector

@Suite("StabilizationOverloadDetector — bypass trigger (slot evictions)")
struct StabilizationOverloadDetectorTests {
    /// 1 s windows, 5% ratio, 2 consecutive windows — small windows keep the test readable;
    /// the production defaults only scale the time axis.
    private func makeDetector() -> StabilizationOverloadDetector {
        StabilizationOverloadDetector(
            windowSeconds: 1.0,
            dropRatioThreshold: 0.05,
            consecutiveWindowsToBypass: 2
        )
    }

    /// Feeds `frames` arrivals at 100 fps starting at `startSeconds`, marking every
    /// `evictEvery`-th frame as evicted. Returns `true` if any record call signalled bypass.
    private func feed(
        _ detector: inout StabilizationOverloadDetector,
        startSeconds: Double,
        frames: Int,
        evictEvery: Int?
    )
    -> Bool {
        var engaged = false
        for index in 0..<frames {
            let evicted = evictEvery.map { index % $0 == ($0 - 1) } ?? false
            let seconds = startSeconds + Double(index) * 0.01
            if detector.record(atSeconds: seconds, evicted: evicted) {
                engaged = true
            }
        }
        return engaged
    }

    @Test("Two consecutive overloaded windows engage bypass")
    func twoOverloadedWindows_engage() {
        var detector = self.makeDetector()
        // 10% evictions across 2.5 s: windows [0,1) and [1,2) both close overloaded; the first
        // frame of the third window observes streak == 2 → bypass.
        let engaged = self.feed(&detector, startSeconds: 0, frames: 250, evictEvery: 10)
        #expect(engaged)
    }

    @Test("A single overloaded window followed by a clean one resets the streak")
    func cleanWindowResetsStreak() {
        var detector = self.makeDetector()
        // Window [0,1): 10% evictions → overloaded.
        var engaged = self.feed(&detector, startSeconds: 0, frames: 100, evictEvery: 10)
        // Window [1,2): clean → streak resets; window [2,3): overloaded again → streak 1.
        engaged = self.feed(&detector, startSeconds: 1.0, frames: 100, evictEvery: nil) || engaged
        engaged = self.feed(&detector, startSeconds: 2.0, frames: 100, evictEvery: 10) || engaged
        // Never two IN A ROW → bypass never engages (transient protection).
        engaged = self.feed(&detector, startSeconds: 3.0, frames: 10, evictEvery: nil) || engaged
        #expect(!engaged)
    }

    @Test("Eviction share at the threshold (exactly 5%) does not count as overload (strict >)")
    func atThreshold_notOverloaded() {
        var detector = self.makeDetector()
        // Exactly 5 evictions per 100 frames per window over 3 windows: ratio == threshold.
        let engaged = self.feed(&detector, startSeconds: 0, frames: 300, evictEvery: 20)
        #expect(!engaged)
    }

    @Test("A long stall spanning several windows inserts clean windows that reset the streak")
    func stallInsertsCleanWindows() {
        var detector = self.makeDetector()
        // Overloaded window [0,1).
        _ = self.feed(&detector, startSeconds: 0, frames: 100, evictEvery: 10)
        // Silence until t=5: the elapsed windows close empty (clean) → streak resets.
        // The overloaded window [5,6) then starts a NEW streak of 1 → no bypass.
        let engaged = self.feed(&detector, startSeconds: 5.0, frames: 100, evictEvery: 10)
        #expect(!engaged)
        #expect(detector.consecutiveOverloadedWindows <= 1)
    }
}

// MARK: - Latency aggregator (AC-8)

@Suite("StabilizationLatencyAggregator — AC-8 report line")
struct StabilizationLatencyAggregatorTests {
    @Test("Percentiles use nearest-rank over the recorded samples")
    func percentiles_nearestRank() {
        var aggregator = StabilizationLatencyAggregator()
        for value in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0] {
            aggregator.record(totalMs: value)
        }
        #expect(aggregator.count == 10)
        #expect(aggregator.percentileMs(0.5) == 60.0)
        #expect(aggregator.percentileMs(0.95) == 100.0)
    }

    @Test("Report line carries p50/p95, frame count, estScale, and the warm-up median")
    func reportLine_containsAllInputs() {
        var aggregator = StabilizationLatencyAggregator()
        aggregator.record(totalMs: 31.2)
        aggregator.record(totalMs: 41.0)
        let line = aggregator.reportLine(estScale: 3, warmUpMedianIntervalMs: 48.3)
        #expect(line.contains("p50="))
        #expect(line.contains("p95="))
        #expect(line.contains("кадров: 2"))
        #expect(line.contains("estScale=3×"))
        #expect(line.contains("медианный интервал warm-up=48.3 мс"))
    }

    @Test("Empty aggregation states 'no measured frames' instead of fabricating percentiles")
    func reportLine_emptyStatesNoFrames() {
        let aggregator = StabilizationLatencyAggregator()
        let line = aggregator.reportLine(estScale: nil, warmUpMedianIntervalMs: nil)
        #expect(line.contains("нет измеренных кадров"))
        #expect(line.contains("estScale=не выбран"))
        #expect(!line.contains("p50="))
    }

    @Test("Report line carries the cumulative error count and the zero-correction fraction")
    func reportLine_containsErrorCountAndZeroCorrectionFraction() {
        var aggregator = StabilizationLatencyAggregator()
        aggregator.record(totalMs: 31.2)
        let line = aggregator.reportLine(
            estScale: 3,
            warmUpMedianIntervalMs: 48.3,
            errorCount: 7,
            zeroCorrectionFraction: 0.25
        )
        #expect(line.contains("ошибок оценки/рендера: 7"))
        #expect(line.contains("доля нулевой коррекции: 25.0%"))
    }

    @Test("Zero-correction fraction states 'not measured' when nil")
    func reportLine_zeroCorrectionFraction_nilStatesNotMeasured() {
        let aggregator = StabilizationLatencyAggregator()
        let line = aggregator.reportLine(estScale: nil, warmUpMedianIntervalMs: nil)
        #expect(line.contains("доля нулевой коррекции: не измерена"))
        #expect(line.contains("ошибок оценки/рендера: 0"))
    }
}
