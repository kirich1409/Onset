// FpsCollapseDetector.swift
// Onset
//
// Pure fps-collapse detector for the camera source (critical-recording-signals, T-A.3).
//
// Design: pure value semantics, time as argument
// ─────────────────────────────────────────────────────────────────────────────
// Like `CFRNormalizer` and `CapabilityResolver`, this is a PURE nonisolated type with no
// framework imports and no clock access. Each step takes the inputs plus a monotonic
// `elapsedSeconds` ARGUMENT and returns a verdict together with an updated detector value —
// the caller (Phase-C coordinator, on a 1 Hz tick) owns the clock and the state. Passing
// time in keeps the L2 tests honest: a test injects a known elapsed series, never a real clock.
//
// Detection (spec §3):
//  - Baseline = sliding average of delivered fps over `cameraBaselineWindowSeconds`, stored as a
//    timestamped sample buffer. Samples whose elapsed < `cameraBaselineSkipSeconds` (cold-start
//    ramp) are not fed into the baseline.
//  - FREEZE: once delivered < `fpsCollapseRatio × baseline`, the baseline is captured as a SCALAR
//    at candidate entry and held constant — dipped samples are neither appended nor evicted while a
//    candidate is active. This prevents the sliding average from self-masking a slow bleed (and keeps
//    the verdict idempotent). Holding a frozen scalar — rather than freezing only the append while
//    eviction continues — matters for candidates longer than the baseline window: an evict-only
//    impl would let the pre-dip high samples age out and the baseline drift down.
//  - FIRING (AND): delivered < `fpsCollapseRatio × baseline` held continuously ≥
//    `fpsCollapseWindowSeconds`, AND a corroborating signal on the current sample (nonzero
//    drop/overflow rate OR `gapMsMax` > `fpsCollapseGapMsThreshold`). A dip without drop/gap
//    (legitimate low-light throttle) does not fire; a drop/gap without a dip does not fire.
//  - Stale input: each sample carries its own `sampleElapsedSeconds`; if it lags the monotonic
//    `elapsedSeconds` by more than `staleSampleMaxAgeSeconds`, the input is discarded (a frozen
//    camera stops flushing — its last fps reading must not be treated as a stable current value).
//
// Isolation: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + NonisolatedNonsendingByDefault.
// All types are `nonisolated`; no Equatable/Hashable conformances are needed here.

import Foundation

// MARK: - FpsCollapseSample

/// One delivered-fps reading handed to the detector each tick.
nonisolated struct FpsCollapseSample {
    /// Delivered (measured) camera fps over the last flush interval.
    nonisolated let deliveredFps: Double

    /// Drop / overflow rate observed alongside this sample. Any value `> 0` corroborates a collapse.
    nonisolated let dropOverflowRate: Double

    /// Largest inter-frame gap (milliseconds) in this sample's interval. Corroborates when it exceeds
    /// `fpsCollapseGapMsThreshold`.
    nonisolated let gapMsMax: Double

    /// The monotonic elapsed time (seconds) at which this sample was produced by the source flush.
    /// Compared against the tick's `elapsedSeconds` to detect a stale (frozen-camera) reading.
    nonisolated let sampleElapsedSeconds: Double
}

// MARK: - FpsCollapseDetector

/// Pure detector that decides whether delivered camera fps has collapsed below its own baseline.
///
/// Value semantics: `step(sample:elapsedSeconds:config:)` returns the verdict plus an updated copy of
/// the detector. The baseline state is seedable via `init` so tests can inject a known baseline +
/// active-candidate state without a 30 s warm-up.
nonisolated struct FpsCollapseDetector {
    // MARK: - Verdict

    /// The outcome of one `step`.
    nonisolated struct Verdict {
        /// `true` when the firing AND-condition held on this step.
        nonisolated let collapsed: Bool

        /// The incident to surface when `collapsed` is `true`, else `nil`. Convenience for the caller.
        nonisolated var incident: CriticalIncident? {
            self.collapsed ? .fpsCollapse : nil
        }

        /// Creates a verdict.
        /// - Parameter collapsed: Whether the collapse AND-condition fired.
        nonisolated init(collapsed: Bool) {
            self.collapsed = collapsed
        }
    }

    // MARK: - Baseline buffer

    /// A timestamped baseline sample: delivered fps measured at a monotonic elapsed time.
    nonisolated struct BaselineSample {
        /// Delivered fps recorded for the baseline average.
        nonisolated let deliveredFps: Double
        /// Monotonic elapsed time (seconds) the value was recorded.
        nonisolated let elapsedSeconds: Double
    }

    // MARK: - State

    /// Rolling baseline samples (age-evicted while no candidate is active). Empty until warm-up passes.
    /// `private(set) nonisolated` order matches SwiftFormat (SwiftLint modifier_order disabled — project
    /// convention, see DropMonitor / CFRNormalizer).
    private(set) nonisolated var baselineSamples: [BaselineSample] // swiftlint:disable:this modifier_order

    /// Frozen baseline scalar captured at candidate entry; `nil` when no candidate is active.
    /// While set, baseline samples are neither appended nor evicted (freeze semantics, spec §3).
    private(set) nonisolated var frozenBaseline: Double? // swiftlint:disable:this modifier_order

    /// Monotonic elapsed time at which the current dip candidate began; `nil` when no candidate active.
    private(set) nonisolated var candidateStartSeconds: Double? // swiftlint:disable:this modifier_order

    /// Maximum age (seconds) a sample may lag the tick's `elapsedSeconds` before being discarded as
    /// stale (frozen camera). Not a `RecordingConfiguration` constant — the spec only requires staleness
    /// ≤ ~1 tick; the exact bound is a detector concern the Phase-C coordinator sets. Default 1.5 s
    /// (≈ 1 tick at 1 Hz + slack).
    nonisolated let staleSampleMaxAgeSeconds: Double

    // MARK: - Init

    /// Creates a detector, optionally seeding baseline / candidate state for tests.
    ///
    /// - Parameters:
    ///   - baselineSamples: Pre-seeded baseline buffer (default empty — production warm-up path).
    ///   - frozenBaseline: Pre-seeded frozen baseline scalar (default `nil` — no active candidate).
    ///   - candidateStartSeconds: Pre-seeded candidate start time (default `nil`).
    ///   - staleSampleMaxAgeSeconds: Stale-input age bound (default 1.5 s).
    nonisolated init(
        baselineSamples: [BaselineSample] = [],
        frozenBaseline: Double? = nil,
        candidateStartSeconds: Double? = nil,
        staleSampleMaxAgeSeconds: Double = 1.5
    ) {
        self.baselineSamples = baselineSamples
        self.frozenBaseline = frozenBaseline
        self.candidateStartSeconds = candidateStartSeconds
        self.staleSampleMaxAgeSeconds = staleSampleMaxAgeSeconds
    }

    // MARK: - Step

    /// Feeds one sample and returns the verdict plus the updated detector.
    ///
    /// - Parameters:
    ///   - sample: The delivered-fps reading for this tick.
    ///   - elapsedSeconds: Monotonic elapsed time of this tick (the clock, supplied by the caller).
    ///   - config: The recording configuration carrying the collapse thresholds.
    /// - Returns: A tuple of the verdict and the next detector state value.
    nonisolated func step(
        sample: FpsCollapseSample,
        elapsedSeconds: Double,
        config: RecordingConfiguration
    )
    -> (verdict: Verdict, next: Self) {
        // Discard a stale reading: a frozen camera stops flushing, so its last fps must not be read as
        // a stable current value. Carry state forward unchanged, no verdict.
        if elapsedSeconds - sample.sampleElapsedSeconds > self.staleSampleMaxAgeSeconds {
            return (Verdict(collapsed: false), self)
        }

        var next = self

        // Skip the cold-start ramp: these readings never feed the baseline.
        let pastWarmup = elapsedSeconds >= config.cameraBaselineSkipSeconds

        // Determine the active baseline: frozen scalar if a candidate is live, else the current average.
        let activeBaseline = next.frozenBaseline ?? next.currentBaselineAverage()

        // A candidate requires a baseline to compare against. Without one (cold start), just accumulate.
        guard let baseline = activeBaseline, baseline > 0 else {
            if pastWarmup {
                next.appendBaseline(sample.deliveredFps, at: elapsedSeconds, window: config.cameraBaselineWindowSeconds)
            }
            return (Verdict(collapsed: false), next)
        }

        let threshold = config.fpsCollapseRatio * baseline
        let belowThreshold = sample.deliveredFps < threshold

        if belowThreshold {
            // Enter / continue a candidate. Freeze the baseline scalar at entry; hold it constant.
            if next.candidateStartSeconds == nil {
                next.candidateStartSeconds = elapsedSeconds
                next.frozenBaseline = baseline
            }

            let dipDuration = elapsedSeconds - (next.candidateStartSeconds ?? elapsedSeconds)
            let sustained = dipDuration >= config.fpsCollapseWindowSeconds
            // Corroboration on the CURRENT sample: nonzero drop/overflow rate (strict) OR an excessive
            // frame gap (strict >). Dip without either → no fire; drop/gap without a dip → no fire.
            let corroborated = sample.dropOverflowRate > 0
                || sample.gapMsMax > Double(config.fpsCollapseGapMsThreshold)

            return (Verdict(collapsed: sustained && corroborated), next)
        }

        // Recovered above threshold: clear the candidate, resume appending to the rolling baseline.
        next.candidateStartSeconds = nil
        next.frozenBaseline = nil
        if pastWarmup {
            next.appendBaseline(sample.deliveredFps, at: elapsedSeconds, window: config.cameraBaselineWindowSeconds)
        }
        return (Verdict(collapsed: false), next)
    }

    // MARK: - Baseline helpers

    /// Average of the current rolling baseline buffer; `nil` when empty.
    nonisolated private func currentBaselineAverage() -> Double? {
        guard !self.baselineSamples.isEmpty else { return nil }
        let total = self.baselineSamples.reduce(0.0) { $0 + $1.deliveredFps }
        return total / Double(self.baselineSamples.count)
    }

    /// Appends a baseline sample and evicts entries older than the window by age.
    nonisolated private mutating func appendBaseline(
        _ deliveredFps: Double,
        at elapsedSeconds: Double,
        window: Double
    ) {
        self.baselineSamples.append(BaselineSample(deliveredFps: deliveredFps, elapsedSeconds: elapsedSeconds))
        let cutoff = elapsedSeconds - window
        self.baselineSamples.removeAll { $0.elapsedSeconds < cutoff }
    }
}
