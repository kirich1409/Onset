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

    /// Starts the session. Throws `RecordingError` on the AC-6 / AC-11 blocking paths. Never throws
    /// `.budgetExceeded` — the session self-adopts the reduced profile (research §3.1).
    func start(permissions: EffectivePermissions) async throws

    /// Stops the session gracefully and returns the assembled result (AC-9). Idempotent /
    /// concurrent-safe in the live implementation (memoized teardown).
    func stop() async -> RecordingResult

    /// The session's current drop health snapshot, polled by the coordinator for the
    /// recording-window drop pill. Returns a zero / never-degraded snapshot before start / after stop.
    func currentDrops() async -> DropHealthSnapshot
}

// MARK: - RecordingSession conformance

/// `RecordingSession` already exposes `recordingStateStream`, `start(permissions:)`, `stop()`, and
/// `currentDrops()` with these exact signatures — conformance is a declaration only.
extension RecordingSession: RecordingControlling {}
