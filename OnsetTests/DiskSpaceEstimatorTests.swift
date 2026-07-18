// DiskSpaceEstimatorTests.swift
// OnsetTests
//
// Swift Testing suite for `DiskSpaceEstimator` (spec #88, T-3).
//
// Pure L2 — no hardware, no wall clock: every sample sequence carries its own
// `elapsedSeconds`, fed through `DiskSpaceEstimator.updateSmoothing` deterministically.
//
// swiftlint:disable file_length
// Rationale: the AC-mapped suites (smoothing, hysteresis, per-volume, reason, idle estimate)
// are kept in one file per the plan's file list — same exemption pattern as FileWriterTests.

@testable import Onset
import Testing

// MARK: - Helpers

/// Builds a `DiskThresholds` fixture with small, hand-checkable numbers (as opposed to the
/// production GB-scale defaults on `RecordingConfiguration.mvpDefault`), so each test's expected
/// math is easy to verify by inspection.
private func makeThresholds(
    systemWarnBytes: Int64 = 1000,
    systemStopBytes: Int64 = 500,
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

/// Folds a scripted `(freeBytes, elapsedSeconds)` sequence through `updateSmoothing`,
/// starting from `SmoothingState.initial` unless a seed state is supplied.
private func feed(
    _ samples: [(freeBytes: Int64, elapsedSeconds: Double)],
    thresholds: DiskThresholds,
    from seed: SmoothingState = .initial
)
-> SmoothingState {
    samples.reduce(seed) { state, sample in
        DiskSpaceEstimator.updateSmoothing(
            state,
            freeBytes: sample.freeBytes,
            elapsedSeconds: sample.elapsedSeconds,
            thresholds: thresholds
        )
    }
}

// MARK: - AC-5: smoothing damps flush bursts, ETA = outputFree / smoothedSpeed

@Suite("DiskSpaceEstimator — smoothing (AC-5)")
struct DiskSpaceEstimatorSmoothingTests {
    @Test("A single flush-burst sample does not falsely trip the ETA-critical threshold")
    func burstSample_doesNotFalselyTripEtaCritical() {
        let thresholds = makeThresholds()
        // Sustained drain ≈ 2.5 bytes/s, one burst tick drains 400 bytes/4s (100 bytes/s) —
        // a naive single-sample ETA would trip critical (9580/100 = 95.8s < 120s), but the
        // EWMA-smoothed speed should stay low enough that it does not.
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (10000, 0),
            (9990, 4),
            (9980, 4),
            (9580, 4), // flush burst
            (9570, 4),
        ]
        let state = feed(samples, thresholds: thresholds)

        let eta = Double(9570) / DiskSpaceEstimator.speed(state)
        #expect(eta > thresholds.outputStopEtaSeconds)

        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 9570,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .none)
    }

    @Test("Window reflects ≥ 4 samples before the EWMA slope is trusted for ETA")
    func window_reflectsAtLeastFourSamples() {
        let thresholds = makeThresholds()
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (10000, 0), (9990, 4), (9980, 4), (9580, 4), (9570, 4),
        ]
        let state = feed(samples, thresholds: thresholds)
        #expect(state.sampleCount == samples.count)
        #expect(state.elapsedTotal == 16)
    }

    @Test("At speed ≤ 0 (growing or flat free space) the byte-floor still yields critical")
    func nonDrainingVolume_byteFloorStillCritical() {
        let thresholds = makeThresholds(outputStopBytes: 200)
        // Free space fluctuates near-flat / growing — smoothed speed will not be positive.
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (150, 0), (160, 4), (150, 4), (160, 4),
        ]
        let state = feed(samples, thresholds: thresholds)
        #expect(DiskSpaceEstimator.speed(state) <= 0)

        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 150,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .critical(.outputFree))
    }

    @Test("Warmup (< 4 samples) suppresses the ETA signal — byte-floor is the only active signal")
    func warmup_fewerThanFourSamples_suppressesEta() {
        let thresholds = makeThresholds(outputWarnBytes: 300, outputStopBytes: 200)
        // A steep single-step drain (125 bytes/s) would trip ETA-critical (500/125 ≈ 4s « 120s)
        // if trusted, but only 2 samples have been applied — not yet warmed up.
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [(1000, 0), (500, 4)]
        let state = feed(samples, thresholds: thresholds)
        #expect(state.sampleCount < 4)

        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 500,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .none)
    }

    @Test("Low slope confidence suppresses ETA-warning; byte-floor remains the sole critical guarantee")
    func lowSlopeConfidence_suppressesEtaWarning_byteFloorStillCritical() {
        let thresholds = makeThresholds(outputWarnBytes: 970, outputStopBytes: 960)
        // Wildly alternating deltas: high variance (low SNR) even once warmed up.
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (1000, 0), (500, 4), (900, 4), (400, 4), (950, 4),
        ]
        let state = feed(samples, thresholds: thresholds)
        #expect(DiskSpaceEstimator.slopeConfidence(state) < 1.0)

        // Byte-floor: 950 <= outputStopBytes(960) → critical, regardless of the noisy slope.
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 950,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .critical(.outputFree))
    }

    @Test("Low slope confidence suppresses an ETA-only warning when the byte-floor is not tripped")
    func lowSlopeConfidence_etaWarningSuppressed_whenByteFloorClear() {
        let thresholds = makeThresholds(outputWarnBytes: 300, outputStopBytes: 200)
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (1000, 0), (500, 4), (900, 4), (400, 4), (950, 4),
        ]
        let state = feed(samples, thresholds: thresholds)
        #expect(DiskSpaceEstimator.slopeConfidence(state) < 1.0)

        // 950 is well above both byte floors — only a (gated) ETA signal could fire here.
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 950,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .none)
    }
}

// MARK: - AC-11: hysteresis / de-escalation dead-band

@Suite("DiskSpaceEstimator — hysteresis (AC-11)")
struct DiskSpaceEstimatorHysteresisTests {
    @Test("Oscillating input around the warn threshold does not flip the verdict every tick")
    func oscillatingInput_doesNotFlipEveryTick() {
        let thresholds = makeThresholds(outputWarnBytes: 1000, outputStopBytes: 200, hysteresisReleaseBytes: 100)
        let state = SmoothingState.initial

        // Tick 1: recovers past the raw threshold but NOT past the release margin (1100) —
        // hysteresis holds the prior warning.
        let tick1 = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 1050,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .warning(.outputFree)
        )
        #expect(tick1 == .warning(.outputFree))

        // Tick 2: dips back under the raw warn threshold — same severity, no hysteresis needed.
        let tick2 = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 980,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: tick1
        )
        #expect(tick2 == .warning(.outputFree))

        // Tick 3: recovers past the release margin (1150 > 1100) — now the warning clears.
        let tick3 = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 1150,
            systemFreeBytes: nil,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: tick2
        )
        #expect(tick3 == .none)
    }

    @Test("Escalation is never delayed by hysteresis")
    func escalation_isImmediate() {
        let thresholds = makeThresholds(outputWarnBytes: 1000, outputStopBytes: 200, hysteresisReleaseBytes: 100)
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 150,
            systemFreeBytes: nil,
            sameVolume: false,
            state: .initial,
            thresholds: thresholds,
            previousVerdict: .warning(.outputFree)
        )
        #expect(verdict == .critical(.outputFree))
    }
}

// MARK: - AC-6: same-volume strictest verdict, external output not held to the OS floor

@Suite("DiskSpaceEstimator — per-volume verdict (AC-6)")
struct DiskSpaceEstimatorVolumeTests {
    @Test("Same volume: the stricter (system) threshold wins even when the output floor has not tripped")
    func sameVolume_strictestVerdictWins() {
        let thresholds = makeThresholds(
            systemWarnBytes: 1000,
            systemStopBytes: 500,
            outputWarnBytes: 300,
            outputStopBytes: 200
        )
        // Output+system report the SAME underlying reading (T-2's contract for sameVolume==true).
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 450,
            systemFreeBytes: 450,
            sameVolume: true,
            state: .initial,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .critical(.systemFree))
    }

    @Test("Different volumes: the OS floor is never applied to the external output volume")
    func differentVolume_osFloorNotAppliedToOutput() {
        let thresholds = makeThresholds(
            systemWarnBytes: 1000,
            systemStopBytes: 500,
            outputWarnBytes: 1000,
            outputStopBytes: 200
        )
        // System volume is healthy; output sits on a spacious external drive at 300 bytes free —
        // below the (irrelevant) system floor of 500 but above the output's own 200 floor.
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 300,
            systemFreeBytes: 50000,
            sameVolume: false,
            state: .initial,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .warning(.outputFree))
    }
}

// MARK: - AC-3: warning verdict carries the correct, actionable reason

@Suite("DiskSpaceEstimator — warning reason (AC-3)")
struct DiskSpaceEstimatorReasonTests {
    @Test("A system-free warning is tagged .systemFree")
    func systemFreeWarning_isTaggedCorrectly() {
        let thresholds = makeThresholds(systemWarnBytes: 1000, outputWarnBytes: 10)
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 100_000,
            systemFreeBytes: 800,
            sameVolume: false,
            state: .initial,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .warning(.systemFree))
    }

    @Test("An output-free warning is tagged .outputFree")
    func outputFreeWarning_isTaggedCorrectly() {
        let thresholds = makeThresholds(systemWarnBytes: 10, outputWarnBytes: 1000)
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 800,
            systemFreeBytes: 100_000,
            sameVolume: false,
            state: .initial,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .warning(.outputFree))
    }

    @Test("An output-ETA warning is tagged .outputEta")
    func outputEtaWarning_isTaggedCorrectly() {
        let thresholds = makeThresholds(
            systemWarnBytes: 10,
            outputWarnBytes: 10,
            outputStopBytes: 5,
            outputWarnEtaSeconds: 650
        )
        // Warmed-up state with a slow, confident, sustained drain whose ETA crosses the warn
        // threshold while free bytes stay well above both byte floors.
        let samples: [(freeBytes: Int64, elapsedSeconds: Double)] = [
            (100_000, 0), (99000, 4), (98000, 4), (97000, 4), (96000, 4),
        ]
        let thresholdsForFeed = makeThresholds(ewmaTimeConstantSeconds: 16, warmupSeconds: 16)
        let state = feed(samples, thresholds: thresholdsForFeed)

        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: 96000,
            systemFreeBytes: 100_000,
            sameVolume: false,
            state: state,
            thresholds: thresholds,
            previousVerdict: .none
        )
        #expect(verdict == .warning(.outputEta))
    }
}

// MARK: - AC-1: idle pre-flight "≈ N мин" estimate

@Suite("DiskSpaceEstimator — idle estimate (AC-1)")
struct DiskSpaceEstimatorIdleEstimateTests {
    private let config = RecordingConfiguration.mvpDefault
    private let plan = ResolvedRecordingPlan(
        displayID: 1,
        screenWidth: 1920,
        screenHeight: 1080,
        screenFps: 30,
        cameraPlan: nil
    )

    @Test("Returns a whole-minute value, rounded to the nearest minute")
    func returnsWholeMinuteValue() {
        // 1920×1080@30 = 12_000_000 bit/s + 128_000 audio = 12_128_000 bit/s = 1_516_000 bytes/s.
        // 151_600_000 bytes / 1_516_000 bytes/s = 100s = 1m40s → rounds to 2 minutes (120s).
        let estimate = DiskSpaceEstimator.idleEstimate(freeBytes: 151_600_000, plan: self.plan, config: self.config)
        #expect(estimate.isEstimateAvailable)
        #expect(estimate.secondsRemaining == 120)
    }

    @Test("A very large free-space reading is still available, past the 60-minute mark")
    func largeFreeSpace_exceedsSixtyMinutes() throws {
        // 1_516_000 bytes/s × 5000s (≈ 83.3 minutes) worth of free space.
        let estimate = DiskSpaceEstimator.idleEstimate(
            freeBytes: 1_516_000 * 5000,
            plan: self.plan,
            config: self.config
        )
        #expect(estimate.isEstimateAvailable)
        let minutes = try #require(estimate.secondsRemaining) / 60
        #expect(minutes > 60)
    }

    @Test("A nil free-bytes reading is unavailable — never a fabricated number")
    func nilFreeBytes_isUnavailable() {
        let estimate = DiskSpaceEstimator.idleEstimate(freeBytes: nil, plan: self.plan, config: self.config)
        #expect(!estimate.isEstimateAvailable)
        #expect(estimate.secondsRemaining == nil)
    }

    @Test("A non-positive free-bytes reading is unavailable")
    func nonPositiveFreeBytes_isUnavailable() {
        let estimate = DiskSpaceEstimator.idleEstimate(freeBytes: 0, plan: self.plan, config: self.config)
        #expect(!estimate.isEstimateAvailable)
        #expect(estimate.secondsRemaining == nil)
    }
}
