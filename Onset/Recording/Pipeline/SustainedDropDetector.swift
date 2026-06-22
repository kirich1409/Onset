// SustainedDropDetector.swift
// Onset
//
// Pure sustained-drop detector (critical-recording-signals, T-A.4).
//
// Design: pure value semantics, time as argument
// ─────────────────────────────────────────────────────────────────────────────
// Like `CFRNormalizer` and `FpsCollapseDetector`, this is a PURE nonisolated type with no
// framework imports and no clock access. The caller supplies the monotonic clock as an
// argument; the detector returns a verdict plus an updated value. Seedable state lets the L2
// tests inject a known degraded-start without elapsing real time.
//
// Two criteria (spec §2):
//  - LIVE: `.degraded` held CONTINUOUSLY ≥ `criticalSustainSeconds` → `hard` (`sustainedDrops`).
//    The detector tracks the start-of-degraded elapsed time; a transient (< threshold) does not
//    fire, and the start resets when degraded clears.
//  - POST-STOP: normalized drop-rate (drops/min) ≥ `criticalDropRatePerMin` AND session duration
//    ≥ `criticalDropRateMinSessionSeconds` (floor). `dropsPerMin = drops × secondsPerMinute /
//    durationSeconds`. The floor guards against a short clip (a 2 s clip with a high drop count
//    must NOT fire).
//
// Isolation: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + NonisolatedNonsendingByDefault.

import Foundation

// MARK: - SustainedDropDetector

/// Pure detector for sustained drop degradation — live (continuous-degraded) and post-stop (rate).
nonisolated struct SustainedDropDetector {
    /// Seconds in a minute — drop-rate normalization factor.
    nonisolated private static let secondsPerMinute = 60.0

    // MARK: - State

    /// Monotonic elapsed time at which the current continuous-degraded span began; `nil` when not
    /// degraded. Reset when degraded clears. `private(set) nonisolated` order matches SwiftFormat
    /// (SwiftLint modifier_order disabled — project convention).
    private(set) nonisolated var degradedStartSeconds: Double? // swiftlint:disable:this modifier_order

    // MARK: - Init

    /// Creates a detector, optionally seeding the degraded-start time for tests.
    /// - Parameter degradedStartSeconds: Pre-seeded start of a continuous-degraded span (default `nil`).
    nonisolated init(degradedStartSeconds: Double? = nil) {
        self.degradedStartSeconds = degradedStartSeconds
    }

    // MARK: - Live

    /// Feeds the current degraded state and returns whether the LIVE sustain threshold has fired,
    /// plus the updated detector.
    ///
    /// Fires `true` once `.degraded` has held continuously for ≥ `criticalSustainSeconds`. The verdict
    /// stays `true` for as long as the span keeps holding past the threshold (windowed-hard; the caller
    /// owns de-escalation/session-cap policy). Clearing degraded resets the span.
    ///
    /// - Parameters:
    ///   - isDegraded: Whether the session is currently `.degraded`.
    ///   - elapsedSeconds: Monotonic elapsed time of this tick (the clock, supplied by the caller).
    ///   - config: The recording configuration carrying `criticalSustainSeconds`.
    /// - Returns: A tuple of `(fired, next)`.
    nonisolated func evaluateLive(
        isDegraded: Bool,
        elapsedSeconds: Double,
        config: RecordingConfiguration
    )
    -> (fired: Bool, next: Self) {
        var next = self

        guard isDegraded else {
            // Degraded cleared → reset the span.
            next.degradedStartSeconds = nil
            return (false, next)
        }

        let start = next.degradedStartSeconds ?? elapsedSeconds
        next.degradedStartSeconds = start
        let heldDuration = elapsedSeconds - start
        let fired = heldDuration >= config.criticalSustainSeconds
        return (fired, next)
    }

    // MARK: - Post-stop

    /// Pure post-stop verdict: whether normalized drop intensity over the session qualifies as `hard`.
    ///
    /// Fires when `dropsPerMin ≥ criticalDropRatePerMin` AND `durationSeconds ≥
    /// criticalDropRateMinSessionSeconds` (floor). Stateless — depends only on its arguments.
    ///
    /// - Parameters:
    ///   - totalDrops: Total drop count accumulated over the session.
    ///   - durationSeconds: Session duration in seconds.
    ///   - config: The recording configuration carrying the rate threshold and the duration floor.
    /// - Returns: `true` when the post-stop hard criterion is met.
    nonisolated static func evaluatePostStop(
        totalDrops: Int,
        durationSeconds: Double,
        config: RecordingConfiguration
    )
    -> Bool {
        // Floor: a clip shorter than the floor can never fire, regardless of drop count.
        guard durationSeconds >= config.criticalDropRateMinSessionSeconds, durationSeconds > 0 else {
            return false
        }
        let dropsPerMin = Double(totalDrops) * Self.secondsPerMinute / durationSeconds
        return dropsPerMin >= Double(config.criticalDropRatePerMin)
    }
}
