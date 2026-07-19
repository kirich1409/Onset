@testable import Onset
import Testing

struct LatencyGraceEstimatorTests {
    /// (a) Cold-start is pessimistic: the estimate sits at the ceiling, well above the floor.
    @Test
    func coldStart_startsAtCeiling_notFloor() {
        let estimator = LatencyGraceEstimator(ceiling: 0.5)

        let grace = estimator.effectiveGrace(fps: 60)

        #expect(grace == 0.5)
        #expect(grace > LatencyGraceEstimator.defaultGrace(fps: 60))
    }

    /// (b) Fast-attack: after relaxing to a low baseline, a single higher Δ lifts grace at
    /// once — in one observe call, not gradually.
    @Test
    func latencyAboveEstimate_raisesGraceImmediately() {
        var estimator = LatencyGraceEstimator(ceiling: 0.5)
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
        var estimator = LatencyGraceEstimator(ceiling: 0.5)
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
        var estimator = LatencyGraceEstimator(ceiling: 0.5)
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

    /// (f) Slow-decay magnitude: once the envelope is pinned high, a single low Δ relaxes it by
    /// exactly one geometric step (× decayFactor) — it does NOT collapse to the new Δ (a degenerate
    /// `envelope = latencySeconds` would) nor to the floor.
    @Test
    func singleLowLatency_decaysGeometrically_notToFloorOrInstant() {
        var estimator = LatencyGraceEstimator(ceiling: 0.5)
        // Relax the pessimistic cold-start below the spike so observe(0.3) pins the envelope at 0.3.
        for _ in 0..<200 {
            estimator.observe(latencySeconds: 0.01)
        }
        estimator.observe(latencySeconds: 0.3)

        estimator.observe(latencySeconds: 0.02)
        let grace = estimator.effectiveGrace(fps: 60)

        // One geometric step: 0.3 × decayFactor = 0.285 — far above the new Δ (0.02) and the floor.
        #expect(abs(grace - 0.3 * LatencyGraceEstimator.decayFactor) < 1e-9)
        #expect(grace > LatencyGraceEstimator.defaultGrace(fps: 60))
    }

    /// (g) Ceiling clamp: a Δ above the ceiling is capped at the ceiling, not adopted verbatim.
    @Test
    func latencyAboveCeiling_isClampedToCeiling() {
        var estimator = LatencyGraceEstimator(ceiling: 0.5)

        estimator.observe(latencySeconds: 0.8)

        #expect(estimator.effectiveGrace(fps: 60) == 0.5)
    }

    /// (h) Observe guard: a negative, NaN, or infinite Δ is ignored — none shifts the envelope.
    @Test
    func invalidLatency_isIgnored() {
        var estimator = LatencyGraceEstimator(ceiling: 0.5)
        // Relax to a baseline ABOVE the per-fps floor so any envelope movement would be visible.
        for _ in 0..<200 {
            estimator.observe(latencySeconds: 0.1)
        }
        let baseline = estimator.effectiveGrace(fps: 60)

        estimator.observe(latencySeconds: -1)
        estimator.observe(latencySeconds: .nan)
        estimator.observe(latencySeconds: .infinity)

        #expect(estimator.effectiveGrace(fps: 60) == baseline)
    }
}
