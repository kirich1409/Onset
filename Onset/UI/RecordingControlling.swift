import Foundation

// MARK: - RecordingControlling

/// The exact surface `RecordingCoordinator` uses of a recording session.
///
/// Abstracts `RecordingSession` (the concrete actor) so the coordinator can be unit-tested without
/// hardware: a fake conformer drives `recordingStateStream` and `currentDrops()` deterministically
/// and returns a synthetic `RecordingResult` from `stop()`. The protocol declares only the
/// orchestration-facing members the coordinator calls — it deliberately does NOT mirror the full
/// `RecordingSession` type (no `init`, no internal pipeline state).
///
/// `nonisolated protocol` so conformers (the `RecordingSession` actor) satisfy the `async`
/// requirements without the protocol itself being inferred `@MainActor` under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `InferIsolatedConformances` — mirrors
/// `EncoderControlling` / `WriterControlling` in `RecordingComponentFactories.swift`.
nonisolated protocol RecordingControlling: Sendable {
    /// Backpressure-health transitions (`RecordingState.normal ↔ .degraded`).
    ///
    /// **Single-consumer.** The coordinator is the ONLY iterator; see `RecordingSession`'s
    /// declaration. Emits only on transitions (no initial `.normal`).
    nonisolated var recordingStateStream: AsyncStream<RecordingState> { get }

    /// Graceful-revocation notifications (AC-12 UI — #39): `.sourceRevoked(kind)` after a source is
    /// revoked + its pipeline finalised, then `.allVideoSourcesLost` when no video pipeline remains.
    ///
    /// **Single-consumer.** The coordinator is the ONLY iterator; see `RecordingSession`'s
    /// declaration. Finishes on `stop()`.
    nonisolated var sourceRevocationStream: AsyncStream<RecordingRevocation> { get }

    /// Screen-capture activation signal (#171).
    ///
    /// On macOS 26 `SCStream.startCapture()` returns **before** the user responds to the consent
    /// dialog, so `start()` returning is not a reliable "recording is live" signal. The recording
    /// UI must NOT appear and the elapsed timer must NOT start until the FIRST real screen frame
    /// actually arrives from ScreenCaptureKit — that is when consent has been granted and capture
    /// is genuinely live.
    ///
    /// This stream yields exactly ONE `Void` element when the first real screen frame is delivered,
    /// then finishes immediately.
    ///
    /// ### Finish behaviour on non-activation
    /// - **Terminal stop** (e.g. SCStream `didStopWithError`) → the session finishes this stream
    ///   WITHOUT yielding. The coordinator treats an empty finish as activation failure.
    /// - **Silent consent denial** → macOS 26 may NOT emit a terminal stop when the user
    ///   dismisses the consent dialog without granting access. In this case the stream may
    ///   never finish. Callers MUST bound the wait independently (the coordinator does,
    ///   with a 30-second timeout backstop via `activationTimeoutSeconds`).
    ///
    /// **Single-consumer.** The coordinator is the ONLY iterator.
    nonisolated var captureActiveStream: AsyncStream<Void> { get }

    /// The session-scoped output subdirectory.
    ///
    /// The URL is valid from `init` — it is computed once at construction time and is
    /// immutable thereafter. The **directory itself is created lazily** in `start()` via
    /// `RecordingOutput.ensureDirectory(_:)`; before `start()` returns, the path may not
    /// yet exist on disk.
    ///
    /// `nonisolated` because `URL` is a value type and the property is set once at init.
    nonisolated var sessionDirectory: URL { get }

    /// The session-start timestamp, shared with the recording files and the technical report name.
    ///
    /// Captured once at `init` (the same `Date` that derives `sessionDirectory`). Exposed so the
    /// coordinator can reconstruct the report file URL for the actionable post-stop notification
    /// (AC-12) without holding a reference to the session after `stop()`.
    ///
    /// `nonisolated` because `Date` is a value type and the property is set once at init.
    nonisolated var sessionStartDate: Date { get }

    /// Starts the session. Throws `RecordingError` on the AC-6 / AC-11 blocking paths. Never throws
    /// `.budgetExceeded` — the session self-adopts the reduced profile (research §3.1).
    func start(permissions: EffectivePermissions) async throws

    /// Stops the session gracefully and returns the assembled result (AC-9). Idempotent /
    /// concurrent-safe in the live implementation (memoized teardown).
    func stop() async -> RecordingResult

    /// The session's current drop health snapshot, polled by the coordinator for the
    /// recording-window drop pill. Returns a zero / never-degraded snapshot before start / after stop.
    func currentDrops() async -> DropHealthSnapshot

    /// The camera lane's latest rate snapshot, pulled ~1 Hz by the coordinator to feed
    /// `FpsCollapseDetector` (critical-recording-signals, Phase B/C). A pure on-demand pull — no
    /// stream, no subscriber. Returns `nil` before the first camera flush, for a screen-only session,
    /// or after teardown. `async` like `currentDrops()` (it reads actor-isolated pipeline state); the
    /// underlying snapshot read on the source is itself lock-based, no second lock.
    func currentRates() async -> CameraRateSnapshot?

    /// Monotonic session-relative elapsed time in seconds (`host_now − sessionT0`), where `sessionT0`
    /// is the session anchor (`HostTimeAnchor.anchorTime`). This is the SAME clock frame as
    /// `CameraRateSnapshot.monotonicStampSeconds`, so the coordinator passes this straight to the pure
    /// detectors as `elapsedSeconds` and the snapshot stamp straight as `sampleElapsedSeconds` with no
    /// conversion — the only way the staleness gate and warmup skip stay correct (critical-recording-
    /// signals, Phase C). CoreMedia stays inside the session; the UI layer never imports it. Returns
    /// `0` before `start()` captures the anchor or after teardown.
    func currentSessionElapsedSeconds() async -> Double
}

// MARK: - RecordingSession conformance

/// `RecordingSession` already exposes `recordingStateStream`, `start(permissions:)`, `stop()`,
/// `currentDrops()`, `currentRates()`, and `currentSessionElapsedSeconds()` with these exact
/// signatures — conformance is a declaration only.
extension RecordingSession: RecordingControlling {}
