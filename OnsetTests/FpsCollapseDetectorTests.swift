@testable import Onset
import Testing

// MARK: - Helpers

private func makeSample(
    fps: Double,
    drop: Double = 0.0,
    gapMs: Double = 0.0,
    at elapsed: Double
)
-> FpsCollapseSample {
    FpsCollapseSample(
        deliveredFps: fps,
        dropOverflowRate: drop,
        gapMsMax: gapMs,
        sampleElapsedSeconds: elapsed
    )
}

/// Seeds a detector with a flat baseline buffer of `fps` covering the window, so the baseline average
/// is a known `fps` without any warm-up.
private func detectorWithBaseline(fps: Double, window: Double, ticks: Int = 10) -> FpsCollapseDetector {
    let samples = (0..<ticks).map { index in
        FpsCollapseDetector.BaselineSample(deliveredFps: fps, elapsedSeconds: Double(index))
    }
    return FpsCollapseDetector(baselineSamples: samples)
}

// MARK: - FpsCollapseDetector tests

@Suite("FpsCollapseDetector — baseline, freeze, AND-corroboration")
struct FpsCollapseDetectorTests {
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - AC-5: collapse with drop/gap fires

    @Test("dip below ratio×baseline sustained past window WITH drops fires collapse")
    func collapse_dipWithDrops_fires() {
        let baselineFps = 30.0
        var detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        let threshold = self.config.fpsCollapseRatio * baselineFps // 0.5 * 30 = 15
        let dippedFps = 10.0
        // Assert the dip genuinely crosses ratio × baseline so the test passes for the right reason.
        #expect(dippedFps < threshold)

        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)
        // Feed the dip continuously with corroborating drops across the window + 1 s.
        for offset in stride(from: 0.0, through: self.config.fpsCollapseWindowSeconds, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: dippedFps, drop: 3.0, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == true)
        #expect(verdict.incident == .fpsCollapse)
    }

    @Test("same dip WITHOUT drops or gap (low-light throttle) does NOT fire")
    func collapse_dipWithoutCorroboration_doesNotFire() {
        let baselineFps = 30.0
        var detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        let dippedFps = 10.0 // below 15 threshold
        #expect(dippedFps < self.config.fpsCollapseRatio * baselineFps)

        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)
        for offset in stride(from: 0.0, through: self.config.fpsCollapseWindowSeconds + 2.0, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: dippedFps, drop: 0.0, gapMs: 0.0, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == false)
    }

    @Test("gap above threshold corroborates even with zero drop rate")
    func collapse_dipWithGapOnly_fires() {
        let baselineFps = 30.0
        var detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        let dippedFps = 10.0
        let bigGap = Double(self.config.fpsCollapseGapMsThreshold) + 50.0
        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)
        for offset in stride(from: 0.0, through: self.config.fpsCollapseWindowSeconds, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: dippedFps, drop: 0.0, gapMs: bigGap, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == true)
    }

    @Test("drop/gap WITHOUT a dip (fps at baseline) does NOT fire")
    func collapse_corroborationWithoutDip_doesNotFire() {
        let baselineFps = 30.0
        var detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)
        // fps stays at baseline (no dip), but drops/gap present → no fire.
        for offset in stride(from: 0.0, through: self.config.fpsCollapseWindowSeconds + 2.0, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: baselineFps, drop: 5.0, gapMs: 999.0, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == false)
    }

    // MARK: - AC-6: freeze works, no self-recovery; slow bleed fires

    @Test("sustained collapse far past the window keeps firing — frozen baseline does not self-heal")
    func collapse_sustainedPastDoubleWindow_doesNotSelfRecover() {
        let baselineFps = 30.0
        let frozen = baselineFps
        // Seed a frozen baseline + active candidate so we test the freeze path directly without warm-up.
        var detector = FpsCollapseDetector(
            baselineSamples: [],
            frozenBaseline: frozen,
            candidateStartSeconds: 100.0
        )
        let dippedFps = 10.0 // below 0.5*30 = 15 against the FROZEN baseline
        #expect(dippedFps < self.config.fpsCollapseRatio * frozen)

        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)
        // Run for ≥ 2× the collapse window. With a frozen scalar baseline, the dip stays below
        // ratio × frozen the whole time → verdict stays collapsed (no drift-induced flip).
        let endOffset = 2.0 * self.config.fpsCollapseWindowSeconds
        for offset in stride(from: 0.0, through: endOffset, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: dippedFps, drop: 2.0, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == true)
        // Baseline scalar held constant across the whole candidate.
        #expect(detector.frozenBaseline == frozen)
    }

    @Test("slow bleed below the frozen baseline WITH drops fires once it crosses ratio×frozen")
    func collapse_slowBleedWithDrops_fires() {
        let baselineFps = 30.0
        var detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        let threshold = self.config.fpsCollapseRatio * baselineFps // 15
        let start = 100.0
        var verdict = FpsCollapseDetector.Verdict(collapsed: false)

        // Bleed below threshold immediately and hold (with drops). Assert the crossing.
        let bledFps = 12.0
        #expect(bledFps < threshold)
        for offset in stride(from: 0.0, through: self.config.fpsCollapseWindowSeconds, by: 1.0) {
            (verdict, detector) = detector.step(
                sample: makeSample(fps: bledFps, drop: 1.0, at: start + offset),
                elapsedSeconds: start + offset,
                config: self.config
            )
        }
        #expect(verdict.collapsed == true)
        // The baseline froze at the pre-bleed average (30), not the bled value.
        #expect(detector.frozenBaseline == baselineFps)
    }

    // MARK: - Stale input

    @Test("a stale sample (older than the age bound) is discarded — state carried forward")
    func step_staleSample_discarded() {
        let baselineFps = 30.0
        let detector = detectorWithBaseline(fps: baselineFps, window: self.config.cameraBaselineWindowSeconds)
        // Sample produced at t=100 but tick is at t=105 → age 5 s >> 1.5 s bound → discarded.
        let (verdict, next) = detector.step(
            sample: makeSample(fps: 1.0, drop: 10.0, at: 100.0),
            elapsedSeconds: 105.0,
            config: self.config
        )
        #expect(verdict.collapsed == false)
        // No candidate started, baseline buffer unchanged.
        #expect(next.candidateStartSeconds == nil)
        #expect(next.frozenBaseline == nil)
    }
}
