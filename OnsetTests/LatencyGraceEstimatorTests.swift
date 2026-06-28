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
}
