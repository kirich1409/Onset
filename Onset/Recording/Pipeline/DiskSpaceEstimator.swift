// swiftlint:disable function_parameter_count
// `evaluate`'s 6 parameters are the plan's approved interface (T-3, tasks.md) — all
// independently required; a wrapper struct would only relocate the field count.

import Foundation

// MARK: - SmoothingState

/// EWMA accumulator for the output volume's free-space drain rate (spec #88).
///
/// Owned by `DiskSpaceMonitor` (T-4) but mutated only through `DiskSpaceEstimator.updateSmoothing`
/// so the smoothing math itself stays pure and directly testable (AC-5). This is a single
/// accumulator + running variance of the recent per-read delta — NOT a ring buffer: an EWMA is
/// naturally time-weighted and needs O(1) state instead of a sample window.
nonisolated struct SmoothingState {
    /// Number of `updateSmoothing` calls applied so far (including the seeding first call).
    nonisolated let sampleCount: Int
    /// Cumulative elapsed seconds across all applied samples — used for the warmup gate
    /// (`DiskThresholds.warmupSeconds`), independent of any fps assumption.
    nonisolated let elapsedTotal: Double
    /// The free-bytes reading from the most recent sample, or `nil` before the first sample.
    nonisolated let lastFreeBytes: Int64?
    /// EWMA of `−Δ(free bytes)/Δt` (bytes/second). Positive means the volume is draining;
    /// negative means free space is growing (e.g. after a large file was deleted elsewhere).
    nonisolated let ewmaSpeed: Double
    /// EWMA mean of the per-read delta, used as the reference point for `deltaVariance`.
    nonisolated let deltaMean: Double
    /// EWMA variance of the per-read delta — the denominator of the `slopeConfidence` SNR proxy.
    nonisolated let deltaVariance: Double

    /// The empty accumulator — no samples applied yet.
    nonisolated static let initial = Self(
        sampleCount: 0,
        elapsedTotal: 0,
        lastFreeBytes: nil,
        ewmaSpeed: 0,
        deltaMean: 0,
        deltaVariance: 0
    )
}

extension SmoothingState: Equatable {}

// MARK: - DiskSpaceEstimator

/// Pure disk-space verdict calculator (spec #88).
///
/// Sits beside `CapabilityResolver` as a `nonisolated` caseless enum of static functions —
/// no framework or actor dependency, so it runs off `MainActor` and is exercised entirely by
/// L2 tests with an injected sample sequence (no wall-clock, no real volume reads).
///
/// Byte-floor thresholds are the PRIMARY critical signal (fire regardless of estimated slope,
/// including a non-draining or growing volume); ETA thresholds are SECONDARY, gated on both
/// warmup and `slopeConfidence` — `...ImportantUsage` includes purgeable space whose recompute
/// swings can dwarf the true write-speed slope near a full volume (see `DiskThresholds` doc).
nonisolated enum DiskSpaceEstimator {
    // MARK: Constants

    /// Minimum sample count before the EWMA slope is trusted for ETA gating (AC-5: "window
    /// contains ≥ 4 samples"). Paired with `DiskThresholds.warmupSeconds` in `isWarmedUp`.
    private static let minimumSlopeSamples = 4

    /// SNR-proxy cutoff below which an ETA-derived threshold is suppressed and only the
    /// byte-floor remains active (spec: "L5 measures the real SNR; at SNR<1 ETA-warning is
    /// gated, stop stays on byte-floor").
    private static let minimumSlopeConfidence = 1.0

    /// Floor for the variance denominator in `slopeConfidence`, avoiding a divide-by-zero
    /// blowup when the recent deltas have been perfectly flat.
    private static let minimumDeltaStandardDeviation = 1.0

    // MARK: - Smoothing (AC-5)

    /// Folds one free-bytes reading into the EWMA accumulator.
    ///
    /// `elapsedSeconds` is the wall-clock gap since the previous reading (injected by the
    /// caller — never `Date()` here, keeping this deterministic for L2 tests). The smoothing
    /// factor is `1 − exp(−Δt / τ)`, the standard EWMA response to irregular sampling
    /// intervals, with `τ = thresholds.ewmaTimeConstantSeconds`.
    ///
    /// - Parameters:
    ///   - state: The accumulator to fold this sample into.
    ///   - freeBytes: The output volume's free-bytes reading for this sample.
    ///   - elapsedSeconds: Seconds since the previous sample (0 for the very first sample).
    ///   - thresholds: Supplies `ewmaTimeConstantSeconds`.
    /// - Returns: The updated accumulator.
    nonisolated static func updateSmoothing(
        _ state: SmoothingState,
        freeBytes: Int64,
        elapsedSeconds: Double,
        thresholds: DiskThresholds
    )
    -> SmoothingState {
        let elapsedTotal = state.elapsedTotal + max(0, elapsedSeconds)

        guard let lastFreeBytes = state.lastFreeBytes, elapsedSeconds > 0 else {
            // First sample (or a zero-duration read): nothing to derive a delta from yet.
            return SmoothingState(
                sampleCount: state.sampleCount + 1,
                elapsedTotal: elapsedTotal,
                lastFreeBytes: freeBytes,
                ewmaSpeed: state.ewmaSpeed,
                deltaMean: state.deltaMean,
                deltaVariance: state.deltaVariance
            )
        }

        // Positive delta == draining (free bytes decreasing).
        let delta = Double(lastFreeBytes - freeBytes) / elapsedSeconds
        let alpha = 1 - exp(-elapsedSeconds / max(thresholds.ewmaTimeConstantSeconds, .leastNormalMagnitude))
        let newEwmaSpeed = state.ewmaSpeed + alpha * (delta - state.ewmaSpeed)

        // EWMA mean/variance of the delta itself — the spread `slopeConfidence` normalizes by.
        let diffFromMean = delta - state.deltaMean
        let newDeltaMean = state.deltaMean + alpha * diffFromMean
        let newDeltaVariance = (1 - alpha) * (state.deltaVariance + alpha * diffFromMean * diffFromMean)

        return SmoothingState(
            sampleCount: state.sampleCount + 1,
            elapsedTotal: elapsedTotal,
            lastFreeBytes: freeBytes,
            ewmaSpeed: newEwmaSpeed,
            deltaMean: newDeltaMean,
            deltaVariance: newDeltaVariance
        )
    }

    /// The current smoothed drain speed (bytes/second). Positive == draining.
    nonisolated static func speed(_ state: SmoothingState) -> Double {
        state.ewmaSpeed
    }

    /// SNR-proxy confidence in the smoothed slope: `|ewmaSpeed| / max(ε, stddev(recentΔ))`.
    ///
    /// Below `minimumSlopeConfidence` the slope is indistinguishable from purgeable-space
    /// recompute noise; ETA-derived thresholds are suppressed (byte-floor stays active).
    nonisolated static func slopeConfidence(_ state: SmoothingState) -> Double {
        let standardDeviation = sqrt(max(state.deltaVariance, 0))
        return abs(state.ewmaSpeed) / max(standardDeviation, Self.minimumDeltaStandardDeviation)
    }

    /// Whether enough samples/time have accumulated to trust the EWMA slope for ETA gating.
    nonisolated private static func isWarmedUp(_ state: SmoothingState, thresholds: DiskThresholds) -> Bool {
        state.sampleCount >= self.minimumSlopeSamples && state.elapsedTotal >= thresholds.warmupSeconds
    }

    // MARK: - Verdict (AC-2/AC-3/AC-4/AC-6/AC-11)

    /// Computes the disk-space verdict for the current tick.
    ///
    /// Byte-floor thresholds are checked first and unconditionally (PRIMARY signal); ETA
    /// thresholds fire only when warmed up and slope-confident (SECONDARY signal). The raw
    /// per-tick verdict is then passed through byte-margin hysteresis against `previousVerdict`
    /// so a metric oscillating around a threshold does not flip the surfaced verdict every tick
    /// (AC-11). `sameVolume` needs no separate branch here: when the output and system paths
    /// resolve to the same physical volume, `outputFreeBytes` and `systemFreeBytes` carry the
    /// same underlying reading (T-2's contract), so independently evaluating both threshold
    /// sets against that one number already yields the strictest verdict (AC-6) — and
    /// `outputFreeBytes` is never compared against the system's stricter thresholds, so an
    /// external output volume is never held to the internal-disk floor.
    ///
    /// - Parameters:
    ///   - outputFreeBytes: Output volume free bytes, or `nil` on a failed read.
    ///   - systemFreeBytes: System volume free bytes, or `nil` on a failed read.
    ///   - sameVolume: Whether the output and system volumes are the same physical volume.
    ///   - state: The current EWMA accumulator (see `updateSmoothing`).
    ///   - thresholds: The configured byte/ETA thresholds and hysteresis parameters.
    ///   - previousVerdict: The verdict surfaced on the previous tick.
    /// - Returns: The verdict to surface this tick.
    nonisolated static func evaluate(
        outputFreeBytes: Int64?,
        systemFreeBytes: Int64?,
        sameVolume: Bool,
        state: SmoothingState,
        thresholds: DiskThresholds,
        previousVerdict: DiskVerdict
    )
    -> DiskVerdict {
        let raw = Self.rawVerdict(
            outputFreeBytes: outputFreeBytes,
            systemFreeBytes: systemFreeBytes,
            state: state,
            thresholds: thresholds
        )
        return Self.applyHysteresis(
            raw: raw,
            previous: previousVerdict,
            outputFreeBytes: outputFreeBytes,
            systemFreeBytes: systemFreeBytes,
            thresholds: thresholds
        )
    }

    /// The verdict from thresholds alone, with no hysteresis against the previous tick.
    nonisolated private static func rawVerdict(
        outputFreeBytes: Int64?,
        systemFreeBytes: Int64?,
        state: SmoothingState,
        thresholds: DiskThresholds
    )
    -> DiskVerdict {
        // Critical, byte-floor first — PRIMARY signal, active regardless of slope/speed.
        if let systemFree = systemFreeBytes, systemFree <= thresholds.systemStopBytes {
            return .critical(.systemFree)
        }
        if let outputFree = outputFreeBytes, outputFree <= thresholds.outputStopBytes {
            return .critical(.outputFree)
        }
        // Critical, ETA — SECONDARY signal, gated on warmup + slope confidence.
        if Self.etaTripped(
            outputFreeBytes: outputFreeBytes,
            state: state,
            thresholds: thresholds,
            etaThresholdSeconds: thresholds.outputStopEtaSeconds
        ) {
            return .critical(.outputEta)
        }
        // Warning, byte floor.
        if let systemFree = systemFreeBytes, systemFree <= thresholds.systemWarnBytes {
            return .warning(.systemFree)
        }
        if let outputFree = outputFreeBytes, outputFree <= thresholds.outputWarnBytes {
            return .warning(.outputFree)
        }
        // Warning, ETA.
        if Self.etaTripped(
            outputFreeBytes: outputFreeBytes,
            state: state,
            thresholds: thresholds,
            etaThresholdSeconds: thresholds.outputWarnEtaSeconds
        ) {
            return .warning(.outputEta)
        }
        return .none
    }

    /// Whether the output volume's estimated time-to-full has crossed `etaThresholdSeconds`.
    ///
    /// Gated on warmup (AC-5: falls back to no-signal, not a fabricated ETA, before enough
    /// samples exist) and on `slopeConfidence` (AC-5/ETA-SNR: a noisy/low-confidence slope
    /// suppresses the ETA signal — the byte-floor above remains the sole critical guarantee).
    nonisolated private static func etaTripped(
        outputFreeBytes: Int64?,
        state: SmoothingState,
        thresholds: DiskThresholds,
        etaThresholdSeconds: Double
    )
    -> Bool {
        guard self.isWarmedUp(state, thresholds: thresholds) else { return false }
        guard self.slopeConfidence(state) >= self.minimumSlopeConfidence else { return false }
        guard let freeBytes = outputFreeBytes, state.ewmaSpeed > 0 else { return false }
        let etaSeconds = Double(freeBytes) / state.ewmaSpeed
        return etaSeconds <= etaThresholdSeconds
    }

    // MARK: - Hysteresis (AC-11)

    /// Applies byte-margin dead-band hysteresis to a de-escalation.
    ///
    /// Escalating (or a same-severity reason change) applies immediately — hysteresis only
    /// guards de-escalation, so a real worsening is never delayed. A de-escalation is accepted
    /// only once the metric behind `previous`'s reason has recovered past its warn threshold by
    /// `hysteresisReleaseBytes` (byte reasons), damping an oscillation whose amplitude is
    /// smaller than the release margin (AC-11). The ETA reason trusts `raw` directly — its own
    /// EWMA smoothing already lags raw oscillation, so a separate margin is redundant. Time-based
    /// debounce (`deescalationDebounceSeconds`) compounds this at the tick-owning layer
    /// (`DiskSpaceMonitor`, T-4), which can require N consecutive recovered ticks; this pure
    /// calculator supplies the per-tick byte-margin dead-band.
    nonisolated private static func applyHysteresis(
        raw: DiskVerdict,
        previous: DiskVerdict,
        outputFreeBytes: Int64?,
        systemFreeBytes: Int64?,
        thresholds: DiskThresholds
    )
    -> DiskVerdict {
        guard severity(raw) < severity(previous) else { return raw }
        guard let previousReason = metricReason(of: previous) else { return raw }

        switch previousReason {
        case .systemFree:
            guard let systemFree = systemFreeBytes else { return previous }
            let recovered = systemFree > thresholds.systemWarnBytes + thresholds.hysteresisReleaseBytes
            return recovered ? raw : previous

        case .outputFree:
            guard let outputFree = outputFreeBytes else { return previous }
            let recovered = outputFree > thresholds.outputWarnBytes + thresholds.hysteresisReleaseBytes
            return recovered ? raw : previous

        case .outputEta:
            return raw
        }
    }

    // MARK: - Idle estimate (AC-1)

    /// Pre-flight "≈ N мин" estimate, computed before any recording session exists.
    ///
    /// Uses the table bitrate sum (screen + camera + audio) rather than a measured slope —
    /// there is no EWMA history yet at idle. Returns `.unavailable`-shaped output
    /// (`isEstimateAvailable == false`) on a nil or non-positive free-bytes reading, or when
    /// the resolved plan's bitrate sum is degenerate, rather than fabricate a number.
    ///
    /// - Parameters:
    ///   - freeBytes: The output volume's free bytes, or `nil` on a failed read.
    ///   - plan: The resolved recording plan (screen + optional camera dimensions/fps).
    ///   - config: Supplies `averageBitrate` and `audioBitrate`.
    /// - Returns: An `ETAEstimate` with `secondsRemaining` rounded to the nearest whole minute.
    nonisolated static func idleEstimate(
        freeBytes: Int64?,
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration
    )
    -> ETAEstimate {
        guard let freeBytes, freeBytes > 0 else {
            return ETAEstimate(secondsRemaining: nil, isEstimateAvailable: false, slopeConfidence: 0)
        }

        let screenBits = config.averageBitrate(
            forWidth: plan.screenWidth,
            height: plan.screenHeight,
            fps: plan.screenFps
        )
        let cameraBits = plan.cameraPlan
            .map { config.averageBitrate(forWidth: $0.width, height: $0.height, fps: $0.fps) } ?? 0
        let totalBitsPerSecond = screenBits + cameraBits + config.audioBitrate

        let bitsPerBytePerSecond = 8.0
        guard totalBitsPerSecond > 0 else {
            return ETAEstimate(secondsRemaining: nil, isEstimateAvailable: false, slopeConfidence: 0)
        }

        let bytesPerSecond = Double(totalBitsPerSecond) / bitsPerBytePerSecond
        let rawSecondsRemaining = Double(freeBytes) / bytesPerSecond

        // Round to the nearest whole minute — the headline is always "≈ N мин", never a
        // fractional/second-precision number that would overstate the estimate's accuracy.
        let secondsPerMinute = 60.0
        let wholeMinuteSeconds = (rawSecondsRemaining / secondsPerMinute).rounded() * secondsPerMinute
        return ETAEstimate(secondsRemaining: wholeMinuteSeconds, isEstimateAvailable: true, slopeConfidence: 0)
    }
}

// MARK: - MetricReason

/// The metric behind a `DiskVerdict`'s reason, unifying `DiskWarningReason`/`DiskStopReason`
/// (same three cases, different enclosing enum) for `DiskSpaceEstimator`'s hysteresis check.
///
/// File-scope (rather than nested in `DiskSpaceEstimator`) purely to keep that enum's body
/// under the strict `type_body_length` budget — this type has no meaning outside this file.
nonisolated private enum MetricReason {
    case outputEta
    case outputFree
    case systemFree
}

/// Extracts the unified `MetricReason` behind a verdict, or `nil` for `.none`.
nonisolated private func metricReason(of verdict: DiskVerdict) -> MetricReason? {
    switch verdict {
    case .none:
        nil

    case let .warning(reason):
        switch reason {
        case .outputEta: .outputEta
        case .outputFree: .outputFree
        case .systemFree: .systemFree
        }

    case let .critical(reason):
        switch reason {
        case .outputEta: .outputEta
        case .outputFree: .outputFree
        case .systemFree: .systemFree
        }
    }
}

/// Ordinal value for `.none` severity — see `severity(_:)`.
nonisolated private let noneSeverity = 0
/// Ordinal value for `.warning` severity — see `severity(_:)`.
nonisolated private let warningSeverity = 1
/// Ordinal value for `.critical` severity — see `severity(_:)`.
nonisolated private let criticalSeverity = 2

/// Ordinal severity of a verdict — `.none` < `.warning` < `.critical`.
nonisolated private func severity(_ verdict: DiskVerdict) -> Int {
    switch verdict {
    case .none: noneSeverity
    case .warning: warningSeverity
    case .critical: criticalSeverity
    }
}

// swiftlint:enable function_parameter_count
