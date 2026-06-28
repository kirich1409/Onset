// LatencyGraceEstimator.swift
// Onset
//
// T-1 of the Continuity-Camera frozen-recording fix (#268) — pure latency-aware
// grace estimator.
//
// Design: pure logic + impure actor (project convention)
// ─────────────────────────────────────────────────────────────────────────────
// The CFR hold-frontier in `VideoEncoder` advances on the wall-clock. Real frames
// land in slots by their capture-PTS, which lags the wall-clock by a delivery
// latency Δ. When Δ exceeds the static `grace`, a frame's slot is already past the
// emitted frontier by the time it ingests → it is dup-dropped and the recording
// freezes (Continuity Camera, Δ ≈ 100–200 ms). The fix is to size `grace` to the
// lane's *actual* capture→ingest latency so real frames reach their slot before a
// hold fills it.
//
// This unit owns the latency→grace math as a `nonisolated` pure value type — same
// split as `CFRNormalizer` / `CapabilityResolver`. `VideoEncoder` feeds it Δ via
// `observe(latencySeconds:)` and reads back `effectiveGrace(fps:)`; no CoreMedia,
// no actor isolation, no syscalls — fully unit-testable without any Apple framework
// or device.
//
// Isolation: under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the type is declared
// `nonisolated` so it is usable from the `VideoEncoder` actor's isolation domain.

import Foundation

// MARK: - LatencyGraceEstimator

/// Tracks the **upper envelope** of observed capture→ingest latency (Δ) and maps it
/// to a CFR `grace` value, so the hold-frontier waits long enough for real frames to
/// arrive in their capture-PTS slot before a synthetic hold fills it.
///
/// ## Why an envelope, not an average
///
/// A frame survives only if `grace > Δ` for *that specific frame*. An EWMA / mean of
/// Δ would leave roughly half of a jittery stream (Continuity jitters 100–200 ms)
/// above `mean + margin`, and those frames would still dup-drop. The estimator
/// therefore follows the **upper bound** of Δ: a peak detector with **fast-attack**
/// (the envelope jumps to Δ the instant Δ rises above it) and **slow-decay** (the
/// envelope relaxes geometrically toward Δ only when Δ stays low). A single high Δ
/// among low ones is fully covered, not averaged away.
///
/// ## Pessimistic cold-start
///
/// The envelope is initialised at `ceiling` (≈ 0.5 s), not at the floor. If it
/// converged upward from the floor instead, the self-clocked frontier would race
/// `lastEmittedSlot` to the wall-present while the estimate was still small → a
/// start-of-session freeze. Starting high and relaxing down avoids that by
/// construction; low-latency lanes converge to their floor within ~1–2 s.
///
/// ## Grace clamping
///
/// `effectiveGrace(fps:)` clamps the envelope into
/// `[max(floor, defaultGrace(fps:)), ceiling]`. The lower bound keeps low-latency
/// lanes (FaceTime built-in, Brio, screen) at their natural per-fps grace (no
/// behaviour change); the ceiling caps growth so a stalled source cannot inflate
/// grace without bound.
nonisolated struct LatencyGraceEstimator {
    // MARK: - Tuning constants

    /// Upper bound on grace (seconds). Caps envelope growth so a stalled / starved
    /// source cannot inflate grace without bound, and seeds the pessimistic
    /// cold-start. ≈ 0.5 s comfortably exceeds observed Continuity Δ (100–200 ms);
    /// calibrate against the measured max Δ in L5 (T-6).
    static let defaultCeilingSeconds = 0.5

    /// Absolute lower bound for `defaultGrace(fps:)` (seconds). Mirrors the existing
    /// `max(5 ms, 2/fps)` grace formula used elsewhere in the encoder.
    static let minimumGraceSeconds = 0.005

    /// Frame-count multiplier in `defaultGrace(fps:)`: the per-fps grace floor is
    /// `frameMultiplier / fps` seconds (two frame intervals).
    static let defaultGraceFrameMultiplier: Double = 2

    /// Per-observation geometric decay applied to the envelope when Δ is below it
    /// (slow-decay). Each low-Δ frame multiplies the envelope by this factor, so it
    /// relaxes toward the current Δ over tens of frames (~1–2 s at 30–60 fps) rather
    /// than collapsing instantly — this is the "slow" half of the peak detector.
    static let decayFactor = 0.95

    // MARK: - State

    /// Absolute lower bound for the effective grace (seconds), supplied at init.
    /// In integration this is `grace ?? defaultGrace(fps)` from `VideoEncoder`; it is
    /// combined with the per-fps `defaultGrace(fps:)` as the clamp's lower bound.
    private let floor: Double

    /// Upper bound for the effective grace (seconds), supplied at init. Caps the
    /// envelope and is the pessimistic cold-start value.
    private let ceiling: Double

    /// Current upper-envelope estimate of Δ (seconds). Initialised to `ceiling`
    /// (pessimistic), driven by `observe(latencySeconds:)`: fast-attack up,
    /// slow-decay down.
    private var envelope: Double

    // MARK: - Init

    /// Creates an estimator with the given grace bounds.
    ///
    /// The envelope starts at `ceiling` (pessimistic cold-start), so `effectiveGrace`
    /// reports `ceiling` until observations relax it downward.
    ///
    /// - Parameters:
    ///   - floor: Absolute lower bound for the effective grace, in seconds.
    ///   - ceiling: Upper bound for the effective grace, in seconds. Also the
    ///     pessimistic cold-start envelope value.
    init(floor: Double, ceiling: Double) {
        self.floor = floor
        self.ceiling = ceiling
        self.envelope = ceiling
    }

    // MARK: - Observation

    /// Folds one observed capture→ingest latency into the upper envelope.
    ///
    /// Peak-detector update: `envelope = max(Δ, envelope × decayFactor)`. When Δ rises
    /// above the (decayed) envelope it is adopted immediately (fast-attack); when Δ is
    /// low the envelope decays geometrically toward it (slow-decay). Negative or
    /// non-finite Δ (NaN, ∞ — e.g. a pre-anchor PTS artifact) are ignored so they
    /// cannot poison the envelope.
    ///
    /// - Parameter latencySeconds: The observed Δ = `clockNow − capturePTS`, in seconds.
    mutating func observe(latencySeconds: Double) {
        guard latencySeconds.isFinite, latencySeconds >= 0 else {
            return
        }

        self.envelope = max(latencySeconds, self.envelope * Self.decayFactor)
    }

    // MARK: - Grace

    /// The grace to use for the given frame rate, in seconds.
    ///
    /// Clamps the current envelope into `[max(floor, defaultGrace(fps:)), ceiling]`.
    /// The caller (`VideoEncoder`) reads this fresh every scheduling cycle.
    ///
    /// - Parameter fps: The lane's target frame rate. Must be > 0.
    /// - Returns: The clamped effective grace in seconds.
    func effectiveGrace(fps: Int) -> Double {
        let lowerBound = max(self.floor, Self.defaultGrace(fps: fps))
        return min(max(self.envelope, lowerBound), self.ceiling)
    }

    /// The per-fps grace floor: `max(minimumGraceSeconds, frameMultiplier / fps)`.
    ///
    /// Matches the encoder's existing static grace formula (`max(5 ms, 2/fps)`) and
    /// forms the per-fps part of `effectiveGrace`'s lower bound.
    ///
    /// - Parameter fps: Target frame rate. Must be > 0.
    /// - Returns: The grace floor in seconds.
    static func defaultGrace(fps: Int) -> Double {
        max(self.minimumGraceSeconds, self.defaultGraceFrameMultiplier / Double(fps))
    }
}
