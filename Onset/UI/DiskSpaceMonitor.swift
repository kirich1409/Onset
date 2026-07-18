import Foundation
import os

// MARK: - Logger

private let diskSpaceMonitorLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DiskSpaceMonitor"
)

// MARK: - MonotonicClock

/// Seam over "the current time" so `DiskSpaceMonitor`'s `readEvery` throttle is testable with no
/// wall-clock sleep. `@MainActor` (implicit under the project's default actor isolation) — the
/// monitor only ever reads it from its own actor, so no `Sendable` crossing is needed.
@MainActor
protocol MonotonicClock {
    /// Current monotonic time in seconds, from an arbitrary but stable-within-process origin.
    /// Only differences between two calls are meaningful — never compare across processes.
    func now() -> Double
}

/// Production `MonotonicClock`, backed by `ProcessInfo.systemUptime` (monotonic, unaffected by
/// wall-clock adjustments — unlike `Date()`).
@MainActor
struct SystemMonotonicClock: MonotonicClock {
    func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - IdlePreflightSnapshot

/// Result of one idle pre-flight read (T-7): the "≈ N мин" headline (AC-1) plus the idle disk
/// verdict (AC-3), both derived from a SINGLE provider snapshot.
@MainActor
struct IdlePreflightSnapshot: Equatable {
    /// The pre-flight ETA estimate shown as the main screen's disk-space headline.
    let estimate: ETAEstimate
    /// The idle disk verdict. Since no EWMA history exists yet, only the byte-floor checks can
    /// trip — the ETA-gated check requires warmup and never fires here.
    let verdict: DiskVerdict
}

// MARK: - DiskSpaceMonitor

/// Owns the `readEvery` XPC-read throttle, the EWMA smoothing window, and the cached disk-space
/// verdict for one recording session (T-4, spec #88).
///
/// This collaborator does NOT decide to post warnings or stop recording — it only refreshes and
/// caches `currentVerdict`; the tick loop (`RecordingCoordinator`, T-6) reads the cache
/// synchronously each second and acts on it. This split keeps the tick itself non-blocking: it
/// never awaits the (potentially slow, XPC-backed) provider read.
///
/// ### Concurrency
/// `refreshInFlight` single-flights the read so overlapping slow refreshes can't apply
/// out-of-order results into `SmoothingState`. `generation` is bumped by `reset()` so a refresh
/// spawned in a prior session (or before a manual reset) that resolves late is detected and
/// dropped rather than contaminating the new session's window.
@MainActor
final class DiskSpaceMonitor {
    // MARK: - Dependencies

    private let provider: any DiskSpaceProviding
    private let configuration: RecordingConfiguration
    private let clock: any MonotonicClock

    // MARK: - Rolling state

    /// EWMA accumulator, mutated only via `DiskSpaceEstimator.updateSmoothing`.
    private var smoothingState: SmoothingState = .initial

    /// Clock time of the last successfully APPLIED read — used for the `readEvery` throttle and
    /// as the `elapsedSeconds` basis for the next `updateSmoothing` call. Left untouched by a
    /// failed (`nil`) read, so a persistently failing provider is retried on the very next tick
    /// instead of waiting out a full `readEvery` window. `nil` before the first read succeeds.
    private var lastReadAt: Double?

    /// The verdict surfaced to the tick loop. Written only when it changes (Equatable-guard) so
    /// there is no per-tick churn on a stable reading.
    private(set) var currentVerdict: DiskVerdict = .none

    /// Number of times `currentVerdict` was actually reassigned. Exists so the Equatable-guard
    /// (no per-tick churn on a stable reading) is directly observable by tests, not just inferred
    /// from `currentVerdict`'s final value.
    private(set) var verdictAssignmentCount = 0

    /// One-shot flag: whether a low-space warning has already been posted for the CURRENT
    /// crossing (owned here so `reset()` can clear it for a new session; T-6 is expected to
    /// consult/clear this alongside its own notifier one-shot bookkeeping).
    private(set) var warningPosted = false

    /// Single-flight guard: a refresh is currently awaiting the provider. `private(set)` so tests
    /// can poll for the `defer`-cleared transition instead of sleeping a fixed duration.
    private(set) var refreshInFlight = false

    /// Bumped by `reset()`. A refresh captures this at spawn time and drops its result if the
    /// value has since changed — the defer-cleared `refreshInFlight` above still lets a *new*
    /// refresh start, this token protects against an *old* refresh's stale result being applied.
    private var generation = 0

    // MARK: - Init

    /// - Parameters:
    ///   - provider: The disk-space read seam (T-2). Live default is the composition root's
    ///     concern (T-9) — this initializer takes it explicitly so tests inject `FakeDiskSpaceProvider`.
    ///   - configuration: Supplies `diskThresholds` (T-1) and the idle-estimate bitrate table.
    ///   - clock: Monotonic time seam — tests inject a fake to advance `readEvery` deterministically.
    init(provider: any DiskSpaceProviding, configuration: RecordingConfiguration, clock: any MonotonicClock) {
        self.provider = provider
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: - Tick-driven refresh (AC-2)

    /// Called by the ~1 Hz tick loop. Spawns a provider read only when `readEverySeconds` has
    /// elapsed since the last APPLIED read AND no refresh is currently in flight — this is what
    /// throttles the actual XPC cadence to `readEverySeconds`, not the tick's own 1 Hz.
    ///
    /// Non-blocking: the spawned `Task` does all provider I/O and state mutation; this method
    /// itself never awaits.
    func tickRefresh(outputURL: URL) {
        guard !self.refreshInFlight else { return }

        let readEvery = self.configuration.diskThresholds.readEverySeconds
        if let lastReadAt, self.clock.now() - lastReadAt < readEvery {
            return
        }

        self.refreshInFlight = true
        let capturedGeneration = self.generation

        Task {
            defer { self.refreshInFlight = false }

            let snapshot = await self.provider.snapshot(outputURL: outputURL)

            // Drop a result from a refresh spawned before a `reset()` (new session) or a
            // superseded generation — applying it would contaminate the new session's smoothing
            // window with a stale (possibly near-full) capacity reading.
            guard capturedGeneration == self.generation else {
                diskSpaceMonitorLogger.debug("disk-space refresh dropped: stale generation")
                return
            }

            self.apply(snapshot: snapshot)
        }
    }

    /// Folds one snapshot into the smoothing window and re-evaluates the cached verdict.
    /// `nil` reads preserve the last-good verdict — never flap to a fabricated verdict on a
    /// single failed read.
    private func apply(snapshot: DiskVolumesSnapshot) {
        guard let outputFreeBytes = snapshot.outputFreeBytes else {
            // Read failure: keep `lastReadAt`, the smoothing window, and the cached verdict all
            // untouched — the next tick retries immediately (the throttle only gates a
            // COMPLETED successful read), and no fabricated sample enters the EWMA.
            diskSpaceMonitorLogger.debug("disk-space refresh returned no output free bytes")
            return
        }

        let now = self.clock.now()
        let elapsedSeconds = self.lastReadAt.map { now - $0 } ?? 0
        self.lastReadAt = now

        self.smoothingState = DiskSpaceEstimator.updateSmoothing(
            self.smoothingState,
            freeBytes: outputFreeBytes,
            elapsedSeconds: elapsedSeconds,
            thresholds: self.configuration.diskThresholds
        )

        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: outputFreeBytes,
            systemFreeBytes: snapshot.systemFreeBytes,
            sameVolume: snapshot.sameVolume,
            state: self.smoothingState,
            thresholds: self.configuration.diskThresholds,
            previousVerdict: self.currentVerdict
        )

        // Equatable-guard: only write (and let SwiftUI/observers react) when the verdict actually
        // changed — a stable reading must not churn `currentVerdict` every `readEvery` tick.
        if verdict != self.currentVerdict {
            self.currentVerdict = verdict
            self.verdictAssignmentCount += 1
        }
    }

    // MARK: - Idle estimate (AC-1)

    /// Pre-flight "≈ N мин" estimate plus the idle disk verdict, computed from ONE fresh snapshot
    /// before any recording session exists (T-7). Seeds a warmup `SmoothingState` (fallback
    /// bitrate speed has no EWMA history yet) with `previousVerdict: .none`, per T-3's contract.
    ///
    /// Both halves share the SAME read — the caller must not read the volume twice for one
    /// idle check (plan.md "Idle DiskVerdict" row) — so this returns both the headline estimate
    /// (AC-1) and the idle verdict (AC-3: a system/output-free warning is possible even before a
    /// recording starts, gated only on the byte-floor checks since there is no EWMA slope yet).
    func idleEstimate(outputURL: URL, plan: ResolvedRecordingPlan) async -> IdlePreflightSnapshot {
        let snapshot = await self.provider.snapshot(outputURL: outputURL)
        let estimate = DiskSpaceEstimator.idleEstimate(
            freeBytes: snapshot.outputFreeBytes,
            plan: plan,
            config: self.configuration
        )
        let verdict = DiskSpaceEstimator.evaluate(
            outputFreeBytes: snapshot.outputFreeBytes,
            systemFreeBytes: snapshot.systemFreeBytes,
            sameVolume: snapshot.sameVolume,
            state: .initial,
            thresholds: self.configuration.diskThresholds,
            previousVerdict: .none
        )
        return IdlePreflightSnapshot(estimate: estimate, verdict: verdict)
    }

    // MARK: - Reset (AC-1 re-estimate)

    /// Clears rolling state for a new recording session: bumps `generation` (so any in-flight
    /// refresh from the prior session is dropped on completion, whether it already unwedged
    /// `refreshInFlight` in its `defer` or not — the two are independent guards), and resets the
    /// smoothing window, cached verdict, and one-shot warning flag.
    func reset() {
        self.generation += 1
        self.smoothingState = .initial
        self.lastReadAt = nil
        self.currentVerdict = .none
        self.warningPosted = false
    }
}
