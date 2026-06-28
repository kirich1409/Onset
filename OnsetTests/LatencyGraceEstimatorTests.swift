@testable import Onset
import Testing

struct LatencyGraceEstimatorTests {
    /// (a) Cold-start is pessimistic: the estimate sits at the ceiling, well above the floor.
    @Test
    func coldStart_startsAtCeiling_notFloor() {
        let estimator = LatencyGraceEstimator(floor: 0.0, ceiling: 0.5)

        let grace = estimator.effectiveGrace(fps: 60)

        #expect(grace == 0.5)
        #expect(grace > LatencyGraceEstimator.defaultGrace(fps: 60))
    }

    /// (b) Fast-attack: after relaxing to a low baseline, a single higher Δ lifts grace at
    /// once — in one observe call, not gradually.
    @Test
    func latencyAboveEstimate_raisesGraceImmediately() {
        var estimator = LatencyGraceEstimator(floor: 0.0, ceiling: 0.5)
        for _ in 0..<500 {
            estimator.observe(latencySeconds: 0.01)
        }
        let relaxed = estimator.effectiveGrace(fps: 30)

        estimator.observe(latencySeconds: 0.2)
        let afterSpike = estimator.effectiveGrace(fps: 30)

        #expect(afterSpike > relaxed)
        #expect(afterSpike >= 0.2)
    }

    /// (c) Slow-decay: a long run of low Δ relaxes the pessimistic cold-start down to the floor.
    @Test
    func sustainedLowLatency_relaxesToFloor() {
        var estimator = LatencyGraceEstimator(floor: 0.0, ceiling: 0.5)
        for _ in 0..<1000 {
            estimator.observe(latencySeconds: 0.001)
        }

        let grace = estimator.effectiveGrace(fps: 60)

        #expect(grace == LatencyGraceEstimator.defaultGrace(fps: 60))
    }

    /// (d) Jitter: a lone high Δ among lows is covered outright by the envelope; an average
    /// would sit far below the spike.
    @Test
    func jitterSpike_isCovered_notAveraged() {
        var estimator = LatencyGraceEstimator(floor: 0.0, ceiling: 0.5)
        for _ in 0..<500 {
            estimator.observe(latencySeconds: 0.02)
        }

        estimator.observe(latencySeconds: 0.3)
        let grace = estimator.effectiveGrace(fps: 60)

        #expect(grace >= 0.3)
    }

    /// (e) Constant mode: `effectiveGrace` returns the fixed value verbatim for any fps — no
    /// per-fps lower bound, no ceiling — and `observe` does not move it.
    @Test
    func constantMode_returnsFixedGrace_andIgnoresObserve() {
        var estimator = LatencyGraceEstimator(constant: 0.005)

        // Pinned exactly, even where defaultGrace(fps) would be far higher (0.0667 at 30 fps).
        #expect(estimator.effectiveGrace(fps: 30) == 0.005)
        #expect(estimator.effectiveGrace(fps: 60) == 0.005)

        // observe is a no-op in constant mode — neither a spike nor a long low run shifts it.
        estimator.observe(latencySeconds: 0.4)
        for _ in 0..<500 {
            estimator.observe(latencySeconds: 0.001)
        }
        #expect(estimator.effectiveGrace(fps: 30) == 0.005)
    }
}
