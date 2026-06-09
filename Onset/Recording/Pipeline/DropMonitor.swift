// DropMonitor.swift
// Onset
//
// #35 — backpressure-degradation monitor.
//
// Path note: the issue/spec call this `Capability/DropMonitor`, but `CapabilityProbe` actually
// lives in `Recording/Pipeline/` and there is no `Capability/` directory. Placed here for
// codebase consistency.
//
// Two-level layering mirrors VideoEncoder (#31):
//   - U-pure: `BackpressureDegradationWindow` — a CoreMedia-free `nonisolated struct` value type
//     fed explicit `Double` seconds. ALL of AC-8's window logic is here and is deterministically
//     testable with no real clock (mirrors `CFRNormalizer`).
//   - U-impure: `actor DropMonitor` — observes per-source `AsyncStream<DropEvent>` channels,
//     routes by `DropReason`, drives the pure window, and emits `RecordingState` transitions.
//     The seconds extraction from `CMTime` happens at this boundary via `CMTimeGetSeconds`.
//
// Isolation: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + NonisolatedNonsendingByDefault.
// `actor DropMonitor` is explicit so the monitor runs off the main actor; all value types are
// `nonisolated` with manual nonisolated Equatable witnesses (mirrors `DropReason`).
//
// file_length: DropCounters, DropBreakdown, BackpressureDegradationWindow, and DropMonitor are
// tightly coupled (shared actor state, shared witness pattern). Splitting them across files
// would duplicate the InferIsolatedConformances rationale. swiftlint:disable file_length

import CoreMedia
import Foundation
import os

// MARK: - DropCounters

/// Cumulative, never-reset drop tallies for the UI (#37) and the AC-9 end-of-session warning.
///
/// Each counter accumulates `DropEvent.count` over the whole session and is NEVER reset — these
/// are distinct from the sliding window that drives `RecordingState`. The three fields map 1-to-1
/// with `DropReason`.
nonisolated struct DropCounters {
    /// Total `DropReason.encoderBackpressureDrops` seen this session. Also the only reason that
    /// feeds the degraded-state window.
    nonisolated let encoderBackpressureDrops: Int

    /// Total `DropReason.captureDrop` seen this session. Never triggers degraded state.
    nonisolated let captureDrops: Int

    /// Total `DropReason.cfrNormalizationDrops` seen this session. Never triggers degraded state.
    nonisolated let cfrNormalizationDrops: Int
}

// MARK: - DropHealthSnapshot

/// End-of-session drop health report combining cumulative counters with the session-level
/// degradation verdict and its dominant cause.
///
/// `sessionEverDegraded` is a one-way latch: it becomes `true` the first time `DropMonitor`
/// transitions to `.degraded` (i.e., the live HUD pill flashed degraded at least once) and
/// never resets within a session. This is intentionally stricter than
/// `encoderBackpressureDrops > 0` — a handful of scattered backpressure drops spread too
/// thinly across the window never trip the degraded state and should not trigger the
/// post-stop warning.
///
/// `dominantCause` identifies the backpressure stage that accumulated the most drops (see
/// `DropCause` tie-break order). `.notDegraded` when the session was never degraded.
nonisolated struct DropHealthSnapshot {
    /// Cumulative per-reason drop tallies (same data as `DropCounters`).
    nonisolated let counters: DropCounters
    /// `true` when the session transitioned to `.degraded` at least once (live HUD flashed).
    nonisolated let sessionEverDegraded: Bool
    /// The backpressure stage that accumulated the most drops, or `.none` if never degraded.
    nonisolated let dominantCause: DropCause
}

// swiftformat:disable:next redundantEquatable
extension DropHealthSnapshot: Equatable {
    /// Manual `nonisolated` implementation (mirrors `DropCounters`).
    nonisolated static func == (lhs: DropHealthSnapshot, rhs: DropHealthSnapshot) -> Bool {
        lhs.counters == rhs.counters
            && lhs.sessionEverDegraded == rhs.sessionEverDegraded
            && lhs.dominantCause == rhs.dominantCause
    }
}

// MARK: - DropBreakdown

/// Per-source diagnostic drop counts accumulated over a session.
///
/// Unlike `DropCounters` (which maps to `DropReason` and drives UI state), `DropBreakdown`
/// maps to `DropSource` and is used EXCLUSIVELY for the single `.notice` log line emitted
/// at session stop. It does not affect UI counters, `RecordingState`, or the degraded-state
/// window — diagnostic only.
nonisolated struct DropBreakdown {
    /// Drops detected by `ScreenSource` (SCStream video overflow).
    nonisolated let captureScreen: Int
    /// Drops detected by `CameraSource` video path (AVCapture video overflow).
    nonisolated let captureCameraVideo: Int
    /// Drops detected by `CameraSource` audio path (AVCapture audio overflow).
    nonisolated let captureCameraAudio: Int
    /// Drops dropped at the `VideoEncoder` pending-frame gate.
    nonisolated let encode: Int
    /// Drops dropped at `FileWriter` due to writer/disk backpressure.
    nonisolated let writer: Int

    /// Single-line `.notice`-level summary for `os.Logger`.
    ///
    /// All values are public (no PII) — safe at `.notice` so the line survives in release
    /// `log show` output, satisfying AC-8's release-diagnosability requirement.
    nonisolated var summaryLine: String {
        "drop breakdown: capture-screen=\(self.captureScreen)" +
            " capture-camera-video=\(self.captureCameraVideo)" +
            " capture-camera-audio=\(self.captureCameraAudio)" +
            " encode=\(self.encode)" +
            " writer=\(self.writer)"
    }
}

// swiftformat:disable:next redundantEquatable
extension DropBreakdown: Equatable {
    /// Manual `nonisolated` implementation (mirrors `DropCounters`).
    nonisolated static func == (lhs: DropBreakdown, rhs: DropBreakdown) -> Bool {
        lhs.captureScreen == rhs.captureScreen
            && lhs.captureCameraVideo == rhs.captureCameraVideo
            && lhs.captureCameraAudio == rhs.captureCameraAudio
            && lhs.encode == rhs.encode
            && lhs.writer == rhs.writer
    }
}

// The synthesised `==` would be inferred `@MainActor` under `InferIsolatedConformances` because
// the conformance is declared in an extension; the manual `nonisolated` witness is required so
// `DropCounters` is comparable from `nonisolated` code (mirrors `RecordingState` / `DropReason`).
// swiftformat:disable:next redundantEquatable
extension DropCounters: Equatable {
    /// Manual `nonisolated` implementation (mirrors `DropReason`).
    nonisolated static func == (lhs: DropCounters, rhs: DropCounters) -> Bool {
        lhs.encoderBackpressureDrops == rhs.encoderBackpressureDrops
            && lhs.captureDrops == rhs.captureDrops
            && lhs.cfrNormalizationDrops == rhs.cfrNormalizationDrops
    }
}

// MARK: - BackpressureDegradationWindow

/// A pure sliding-window state machine over backpressure-drop timestamps (AC-8).
///
/// Deliberately a value type with no actor isolation, no CoreMedia import, and no clock: it is fed
/// explicit `Double` seconds by the actor (which extracts them from `CMTime` via `CMTimeGetSeconds`
/// at the boundary). This keeps every AC-8 rule — threshold crossing, historical-drop eviction,
/// and recovery — deterministically testable with synthetic seconds.
///
/// ## Window semantics
///
/// The buffer holds the second-stamps of backpressure drops only. An entry is "in window" at time
/// `now` when `stamp >= now − windowSeconds` (entries strictly older are evicted). The window is
/// `.degraded` when its in-window count `> threshold` (strict, per spec).
///
/// ## `DropEvent.count` mapping
///
/// AC-8 counts *drops* in the window, not *events* — so a `DropEvent` with `count == N` records its
/// timestamp `N` times. `record(atSeconds:count:)` appends `count` copies. (Equivalent to storing
/// `(seconds, count)` pairs and summing; the repeat-append form is chosen because eviction is then
/// a single uniform `removeAll(where:)` over a flat buffer.)
///
/// ## Recovery (Live)
///
/// `evaluate(nowSeconds:)` evicts by `now` and re-reads the count without appending. This is what
/// drives recovery to `.normal` when no new drops arrive — the actor's periodic tick calls it with
/// the host-clock seconds so a quiet window empties over time.
nonisolated struct BackpressureDegradationWindow {
    // MARK: - Configuration

    /// Sliding-window length in seconds. Entries older than `now − windowSeconds` are evicted.
    nonisolated let windowSeconds: Double

    /// In-window drop count above which the window reports degraded. Strict: `count > threshold`.
    nonisolated let threshold: Int

    // MARK: - State

    /// Second-stamps of backpressure drops currently inside the window. One entry per dropped
    /// frame (a `DropEvent` with `count == N` contributes `N` entries — see type doc).
    private(set) nonisolated var stamps: [Double] = [] // swiftlint:disable:this modifier_order

    // MARK: - Init

    /// - Parameters:
    ///   - windowSeconds: Sliding-window length. Must be > 0.
    ///   - threshold: Strict in-window count above which the window is degraded. Must be ≥ 0.
    nonisolated init(windowSeconds: Double, threshold: Int) {
        precondition(windowSeconds > 0, "windowSeconds must be positive")
        precondition(threshold >= 0, "threshold must be non-negative")
        self.windowSeconds = windowSeconds
        self.threshold = threshold
    }

    // MARK: - Recording

    /// Records `count` backpressure drops detected at `atSeconds`, evicts stale entries relative to
    /// that same instant, and returns whether the window is now degraded (`count > threshold`).
    ///
    /// `atSeconds` doubles as "now" for eviction: a fresh drop is the most recent point in time, so
    /// any entry older than `atSeconds − windowSeconds` has aged out.
    ///
    /// ASSUMPTION: `atSeconds` is monotonically non-decreasing across successive calls. If a
    /// non-monotonic timestamp is passed (e.g. after a source-clock reset), `atSeconds` acts as
    /// an earlier "now" for eviction and would incorrectly evict valid in-window entries, causing
    /// the window to under-count drops. The live caller uses a monotonic host clock so this does
    /// not occur in practice; no precondition is asserted here to avoid crashing in edge cases.
    ///
    /// - Parameters:
    ///   - atSeconds: Host-clock seconds at which the drops were detected (monotonically non-decreasing).
    ///   - count: Number of drops in this event (≥ 1). Appended `count` times — AC-8 counts drops.
    /// - Returns: `true` when the in-window drop count exceeds `threshold`.
    nonisolated mutating func record(atSeconds: Double, count: Int) -> Bool {
        precondition(count >= 1, "count must be at least 1")
        for _ in 0..<count {
            self.stamps.append(atSeconds)
        }
        return self.evaluate(nowSeconds: atSeconds)
    }

    // MARK: - Evaluation (recovery)

    /// Evicts entries older than `nowSeconds − windowSeconds` and returns whether the window is
    /// still degraded. No new entry is appended — this is the recovery probe driven by the actor's
    /// periodic tick (Live-recovery): a window with no fresh drops empties and returns `false`.
    ///
    /// - Parameter nowSeconds: Current host-clock seconds.
    /// - Returns: `true` when the surviving in-window drop count exceeds `threshold`.
    nonisolated mutating func evaluate(nowSeconds: Double) -> Bool {
        let cutoff = nowSeconds - self.windowSeconds
        // Strictly-older entries age out; an entry exactly on the cutoff is still in-window.
        self.stamps.removeAll { $0 < cutoff }
        return self.stamps.count > self.threshold
    }
}

// MARK: - DropMonitor

/// Observes per-source drop channels and surfaces backpressure-degradation state to the UI (#37).
///
/// One monitor per recording session. Sources (encoders, capture sources, FileWriters) each expose
/// a `drops: AsyncStream<DropEvent>`; `observe(_:)` subscribes to each. Routing by `DropReason`:
/// - `.encoderBackpressureDrops` → cumulative `encoderBackpressureDrops` AND the sliding window
///   (the only reason that can trigger `.degraded`).
/// - `.captureDrop` → cumulative `captureDrops` only (never triggers).
/// - `.cfrNormalizationDrops` → cumulative `cfrNormalizationDrops` only (never triggers).
///
/// ### Degraded = Live with recovery (user decision)
/// The window goes `.degraded` when backpressure drops in the last `degradedWindowSeconds` exceed
/// `degradedBackpressureThreshold`, and recovers to `.normal` once the window clears. A periodic
/// tick reads the host clock and calls `BackpressureDegradationWindow.evaluate` so recovery fires
/// even when no new drops arrive. `RecordingState` is emitted on `state` only on TRANSITIONS.
///
/// ### Lifecycle / teardown
/// `stop()` is the primary terminator: it cancels and awaits the tick task, cancels the observe
/// child tasks, and finishes the `state` stream (mirrors `VideoEncoder.stop()`'s finish-always
/// discipline). `deinit` is a best-effort safety net — it can only cancel tasks and `finish()` the
/// continuation (both thread-safe, no `await`).
actor DropMonitor {
    // MARK: - Logging

    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "DropMonitor"
    )

    // MARK: - State stream

    /// Backpressure-health transitions for the UI (#37). Emits ONLY on `.normal ↔ .degraded`
    /// changes — never per recompute, and no initial `.normal` emission.
    nonisolated let state: AsyncStream<RecordingState>
    private let stateContinuation: AsyncStream<RecordingState>.Continuation

    // MARK: - Degradation tracking

    /// Pure sliding window over backpressure-drop timestamps (AC-8). Mutated only inside the actor.
    private var window: BackpressureDegradationWindow

    /// The last state EMITTED on `state`. Transition gate: a recompute yields only when the new
    /// value differs from this. Initialised to `.normal` (the implicit starting state) so the
    /// first emission is the first real transition, not a redundant `.normal`.
    private var currentState: RecordingState = .normal

    // MARK: - Cumulative counters (never reset)

    private var encoderBackpressureDrops = 0
    private var captureDrops = 0
    private var cfrNormalizationDrops = 0

    // MARK: - Degradation latch (never reset within a session)

    /// One-way latch: set to `true` on the first `.normal → .degraded` transition, never reset.
    /// Used by `snapshot()` to populate `DropHealthSnapshot.sessionEverDegraded` so the post-stop
    /// warning is aligned with whether the live HUD pill actually flashed degraded.
    private var sessionEverDegraded = false

    // MARK: - Backpressure-only per-source counters (never reset)

    // These count ONLY encoderBackpressureDrops events, keyed by DropSource. They are separate
    // from breakdownCaptureScreen / breakdownEncode / etc. (which count ALL reasons) so that
    // CFR-normalization and captureDrop events never misattribute the dominant backpressure cause.
    // Incremented exclusively inside the .encoderBackpressureDrops branch of ingest(_:).
    private var bpCaptureScreen = 0
    private var bpCaptureCameraVideo = 0
    private var bpCaptureCameraAudio = 0
    private var bpEncode = 0
    private var bpWriter = 0

    // MARK: - Per-source diagnostic counters (never reset)

    // These parallel the DropReason counters above but are keyed by DropSource, not DropReason.
    // They feed the single .notice summary line at stop() — they do NOT replace or modify the
    // DropReason accounting above. An event with reason .encoderBackpressureDrops increments
    // both encoderBackpressureDrops (existing) AND one source bucket below (new). The totals
    // are independent: the reason total drives UI; the source total drives diagnostics.
    private var breakdownCaptureScreen = 0
    private var breakdownCaptureCameraVideo = 0
    private var breakdownCaptureCameraAudio = 0
    private var breakdownEncode = 0
    private var breakdownWriter = 0

    // MARK: - Tasks

    /// One child task per observed source stream. Cancelled on `stop()` / `deinit`.
    private var observeTasks: [Task<Void, Never>] = []

    /// The periodic recovery tick. Reads the host clock and re-evaluates the window so a quiet
    /// window recovers to `.normal`. Cancelled + awaited on `stop()`.
    private var tickTask: Task<Void, Never>?

    /// Tick interval (seconds). A fraction of the window so recovery is observed promptly without
    /// busy-spinning. Derived from `windowSeconds` at init.
    private let tickIntervalSeconds: Double

    // MARK: - Init

    /// - Parameters:
    ///   - windowSeconds: Sliding-window length (from `RecordingConfiguration.degradedWindowSeconds`).
    ///   - threshold: Backpressure-drop threshold (`RecordingConfiguration.degradedBackpressureThreshold`).
    init(windowSeconds: Double, threshold: Int) {
        precondition(windowSeconds > 0, "windowSeconds must be positive")
        self.window = BackpressureDegradationWindow(windowSeconds: windowSeconds, threshold: threshold)

        // Tick at a quarter of the window: frequent enough that recovery is observed within one
        // window of the last drop, infrequent enough to stay off the hot path.
        let tickFraction = 4.0
        self.tickIntervalSeconds = windowSeconds / tickFraction

        let (stream, continuation) = AsyncStream.makeStream(of: RecordingState.self)
        self.state = stream
        self.stateContinuation = continuation
    }

    deinit {
        // Best-effort safety net only — no `await` is possible in deinit. `stop()` is the primary,
        // ordered terminator. Cancelling tasks and finishing the continuation are thread-safe.
        self.tickTask?.cancel()
        for task in self.observeTasks {
            task.cancel()
        }
        self.stateContinuation.finish()
    }

    // MARK: - Observation

    /// Subscribes to one source's drop channel. Spawns a child task that reads the stream to
    /// completion, routing each `DropEvent` through `ingest(_:)`. Call once per source (encoders,
    /// capture sources, FileWriters). Starts the periodic recovery tick on first observation.
    ///
    /// - Parameter drops: A source's `drops: AsyncStream<DropEvent>` channel.
    func observe(_ drops: AsyncStream<DropEvent>) {
        if self.tickTask == nil {
            self.startTick()
        }
        let task = Task { [weak self] in
            for await event in drops {
                guard let self else { return }
                await self.ingest(event)
            }
        }
        self.observeTasks.append(task)
    }

    // swiftlint:disable cyclomatic_complexity
    /// Routes a single drop event: bumps the cumulative counter for its reason, and — for
    /// backpressure only — feeds the window and recomputes `RecordingState`. Also accumulates
    /// the per-source diagnostic breakdown (independent path, no effect on reason counters).
    private func ingest(_ event: DropEvent) {
        // Reason accounting: drives UI counters and degraded-state window.
        switch event.reason {
        case .encoderBackpressureDrops:
            self.encoderBackpressureDrops += event.count
            let detectedAtSeconds = CMTimeGetSeconds(event.detectedAt)
            let degraded = self.window.record(atSeconds: detectedAtSeconds, count: event.count)
            self.applyDegraded(degraded)

            // Backpressure-only per-source tally: incremented exclusively inside this branch so
            // captureDrop and cfrNormalizationDrops events never misattribute dominant cause.
            switch event.source {
            case .captureScreen:
                self.bpCaptureScreen += event.count

            case .captureCameraVideo:
                self.bpCaptureCameraVideo += event.count

            case .captureCameraAudio:
                self.bpCaptureCameraAudio += event.count

            case .encode:
                self.bpEncode += event.count

            case .writer:
                self.bpWriter += event.count
            }

        case .captureDrop:
            // Counted for the AC-9 end-of-session warning; never a degraded-state trigger.
            self.captureDrops += event.count

        case .cfrNormalizationDrops:
            // Counted for the AC-9 end-of-session warning; never a degraded-state trigger.
            self.cfrNormalizationDrops += event.count
        }

        // Source accounting: diagnostic only — independent of reason accounting above.
        switch event.source {
        case .captureScreen:
            self.breakdownCaptureScreen += event.count

        case .captureCameraVideo:
            self.breakdownCaptureCameraVideo += event.count

        case .captureCameraAudio:
            self.breakdownCaptureCameraAudio += event.count

        case .encode:
            self.breakdownEncode += event.count

        case .writer:
            self.breakdownWriter += event.count
        }
    }

    // swiftlint:enable cyclomatic_complexity

    // MARK: - Recovery tick

    /// Spawns the periodic recovery loop. Each tick reads the host clock (`PipelineClock`, same
    /// epoch as `DropEvent.detectedAt`), evaluates the window, and recomputes state. Driving
    /// recovery from a real clock — not `Date()` on main — satisfies the spec timing constraint.
    private func startTick() {
        let nanosPerSecond = 1_000_000_000.0
        let nanosPerTick = UInt64(self.tickIntervalSeconds * nanosPerSecond)
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanosPerTick)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// One recovery tick: re-evaluate the window against the current host time and recompute state.
    /// Recovers `.degraded → .normal` when the window has emptied. No-op effect on `state` unless a
    /// transition crosses.
    func tick() {
        self.evaluate(nowSeconds: CMTimeGetSeconds(PipelineClock.currentHostTime()))
    }

    /// Test seam: evaluate the window at an explicit time, bypassing the real clock. Mirrors
    /// `VideoEncoder.clockTick(nowSeconds:)` — lets actor tests drive recovery deterministically.
    func evaluate(nowSeconds: Double) {
        let degraded = self.window.evaluate(nowSeconds: nowSeconds)
        self.applyDegraded(degraded)
    }

    // MARK: - Transition emission

    /// The single transition gate. Maps the window's degraded flag to a `RecordingState` and emits
    /// on `state` ONLY when it differs from the last-emitted value. Both the `record` path
    /// (normal→degraded) and the `evaluate`/`tick` path (degraded→normal) route through here, so
    /// the stream never sees a duplicate or an initial `.normal`.
    private func applyDegraded(_ degraded: Bool) {
        let newState: RecordingState = degraded ? .degraded : .normal
        guard newState != self.currentState else { return }
        self.currentState = newState
        if newState == .degraded {
            // One-way latch: set on the first .normal → .degraded transition, never reset.
            self.sessionEverDegraded = true
        }
        self.logger.notice("recording state → \(degraded ? "degraded" : "normal", privacy: .public)")
        self.stateContinuation.yield(newState)
    }

    // MARK: - Snapshot

    /// Current drop health snapshot for the session, combining cumulative counters with the
    /// degradation latch and dominant backpressure cause. Used by `RecordingSession.stop()`
    /// to assemble `RecordingResult` and by `currentDrops()` (polled by the live drop pill).
    func snapshot() -> DropHealthSnapshot {
        DropHealthSnapshot(
            counters: DropCounters(
                encoderBackpressureDrops: self.encoderBackpressureDrops,
                captureDrops: self.captureDrops,
                cfrNormalizationDrops: self.cfrNormalizationDrops
            ),
            sessionEverDegraded: self.sessionEverDegraded,
            dominantCause: self.computeDominantCause()
        )
    }

    /// Returns the backpressure stage that accumulated the most drops, using the deterministic
    /// tie-break order: writer > encode > captureScreen > captureCameraVideo > captureCameraAudio.
    /// Returns `.none` when no backpressure drops occurred.
    private func computeDominantCause() -> DropCause {
        // Tie-break order (highest priority first): writer > encode > captureScreen >
        // captureCameraVideo > captureCameraAudio. The first non-zero bucket among those
        // with the highest count wins; ties use this order as a deterministic decider.
        let candidates: [(Int, DropCause)] = [
            (self.bpWriter, .writer),
            (self.bpEncode, .encode),
            (self.bpCaptureScreen, .captureScreen),
            (self.bpCaptureCameraVideo, .captureCameraVideo),
            (self.bpCaptureCameraAudio, .captureCameraAudio),
        ]
        guard let maxCount = candidates.map(\.0).max(), maxCount > 0 else { return .notDegraded }
        return candidates.first { $0.0 == maxCount }?.1 ?? .notDegraded
    }

    /// Current per-source diagnostic breakdown. Counters are never reset. Used by `stop()` to
    /// emit the session-end summary and exposed for testing.
    func breakdownSnapshot() -> DropBreakdown {
        DropBreakdown(
            captureScreen: self.breakdownCaptureScreen,
            captureCameraVideo: self.breakdownCaptureCameraVideo,
            captureCameraAudio: self.breakdownCaptureCameraAudio,
            encode: self.breakdownEncode,
            writer: self.breakdownWriter
        )
    }

    // MARK: - Lifecycle

    /// Primary terminator: cancels and awaits the recovery tick, cancels and awaits the observe
    /// child tasks, then finishes the `state` stream. Idempotent — finishing an already-finished
    /// continuation is a no-op. Awaiting the observe tasks before finishing the continuation
    /// ensures deterministic teardown: any in-flight `ingest(_:)` call that holds the actor
    /// completes before the stream is closed, eliminating reliance on yield-after-finish being a
    /// no-op. Mirrors `VideoEncoder.stop()`'s finish-always discipline.
    ///
    /// Emits a single `.notice` per-source diagnostic summary after all observe tasks drain —
    /// counts are final at this point and survive in release `log show` output (AC-8).
    func stop() async {
        self.tickTask?.cancel()
        await self.tickTask?.value
        self.tickTask = nil
        for task in self.observeTasks {
            task.cancel()
        }
        for task in self.observeTasks {
            await task.value
        }
        self.observeTasks.removeAll()
        let breakdown = self.breakdownSnapshot()
        self.logger.notice("\(breakdown.summaryLine, privacy: .public)")
        self.stateContinuation.finish()
    }
}
