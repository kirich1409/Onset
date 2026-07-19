@testable import Onset
import Testing

// MARK: - SustainedDropDetector tests

@Suite("SustainedDropDetector — pure live + post-stop verdicts")
struct SustainedDropDetectorTests {
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - Live (AC-3a)

    @Test("degraded held continuously to the sustain threshold fires hard")
    func live_degradedAtThreshold_fires() {
        var detector = SustainedDropDetector()

        // Degraded starts at t=0.
        (_, detector) = detector.evaluateLive(isDegraded: true, elapsedSeconds: 0.0, config: self.config)
        // Just before the threshold — not yet.
        var fired: Bool
        (fired, detector) = detector.evaluateLive(
            isDegraded: true,
            elapsedSeconds: self.config.criticalSustainSeconds - 0.1,
            config: self.config
        )
        #expect(fired == false)

        // At the threshold — fires.
        (fired, detector) = detector.evaluateLive(
            isDegraded: true,
            elapsedSeconds: self.config.criticalSustainSeconds,
            config: self.config
        )
        #expect(fired == true)
    }

    @Test("transient degraded shorter than the threshold does not fire")
    func live_transientBelowThreshold_doesNotFire() {
        var detector = SustainedDropDetector()
        (_, detector) = detector.evaluateLive(isDegraded: true, elapsedSeconds: 0.0, config: self.config)
        var fired: Bool
        (fired, detector) = detector.evaluateLive(
            isDegraded: true,
            elapsedSeconds: self.config.criticalSustainSeconds - 0.5,
            config: self.config
        )
        #expect(fired == false)
    }

    @Test("clearing degraded resets the span — a later degraded restarts the clock")
    func live_clearingDegraded_resetsSpan() {
        var detector = SustainedDropDetector()
        (_, detector) = detector.evaluateLive(isDegraded: true, elapsedSeconds: 0.0, config: self.config)
        // Clear at t=5 (before threshold).
        (_, detector) = detector.evaluateLive(isDegraded: false, elapsedSeconds: 5.0, config: self.config)
        // Degraded again at t=6; at t=6 + (threshold - 1) it must NOT have fired (span restarted at 6).
        (_, detector) = detector.evaluateLive(isDegraded: true, elapsedSeconds: 6.0, config: self.config)
        var fired: Bool
        (fired, detector) = detector.evaluateLive(
            isDegraded: true,
            elapsedSeconds: 6.0 + self.config.criticalSustainSeconds - 1.0,
            config: self.config
        )
        #expect(fired == false)
    }

    // MARK: - Post-stop (AC-4)

    @Test("rate at or above threshold with duration above the floor fires")
    func postStop_rateAndDurationAboveFloor_fires() {
        // duration well above the floor; drops chosen so drops/min ≥ criticalDropRatePerMin.
        let duration = 60.0 // 1 minute
        let drops = self.config.criticalDropRatePerMin // exactly the rate at 1 min
        let fired = SustainedDropDetector.evaluatePostStop(
            totalDrops: drops,
            durationSeconds: duration,
            config: self.config
        )
        #expect(fired == true)
    }

    @Test("short clip below the duration floor does not fire despite a high drop count")
    func postStop_shortClipBelowFloor_doesNotFire() {
        // 2 s clip with a high drop count: drops/min would be huge, but the floor blocks it.
        let duration = 2.0
        let drops = 21 // 21 drops in 2 s = 630/min, above rate — but floor (10 s) blocks
        #expect(duration < self.config.criticalDropRateMinSessionSeconds)
        let fired = SustainedDropDetector.evaluatePostStop(
            totalDrops: drops,
            durationSeconds: duration,
            config: self.config
        )
        #expect(fired == false)
    }

    @Test("duration above the floor but rate below threshold does not fire")
    func postStop_lowRateAboveFloor_doesNotFire() {
        let duration = 60.0
        let drops = self.config.criticalDropRatePerMin - 1 // just under the rate at 1 min
        let fired = SustainedDropDetector.evaluatePostStop(
            totalDrops: drops,
            durationSeconds: duration,
            config: self.config
        )
        #expect(fired == false)
    }
}
