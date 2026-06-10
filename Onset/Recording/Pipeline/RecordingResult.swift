import Foundation

// MARK: - SessionOutput

/// The file-level output of a completed recording session.
///
/// Mirrors the three valid combinations of pipelines that `RecordingStartPlan` can produce —
/// screen-only, camera-only, or both — making `(screen: nil, camera: nil)` unrepresentable at
/// the type level. A failable `init?` bridges from the dictionary produced by
/// `DualFileOutputStage.finishAll()` for the few remaining non-typesafe sites.
///
/// `SessionOutput` is intentionally NOT `Equatable` — `FinishResult.failed` carries an `Error`
/// payload and `Error` has no guaranteed `Equatable` conformance.
///
/// Note: `RecordingOutput` is already taken (a utility namespace in `Storage/RecordingOutput.swift`).
nonisolated enum SessionOutput {
    /// Only the screen pipeline ran and produced a result.
    case screenOnly(FinishResult)
    /// Only the camera pipeline ran and produced a result.
    case cameraOnly(FinishResult)
    /// Both pipelines ran and produced results.
    case both(screen: FinishResult, camera: FinishResult)

    // MARK: - Failable init

    /// Builds a `SessionOutput` from optional per-pipeline results.
    ///
    /// Returns `nil` when both arguments are `nil` (degenerate empty — stop fired before any
    /// sample reached a writer). All other combinations map to one of the three enum cases.
    nonisolated init?(screen screenResult: FinishResult?, camera cameraResult: FinishResult?) {
        switch (screenResult, cameraResult) {
        case let (scr?, cam?):
            self = .both(screen: scr, camera: cam)

        case let (scr?, nil):
            self = .screenOnly(scr)

        case let (nil, cam?):
            self = .cameraOnly(cam)

        case (nil, nil):
            return nil
        }
    }
}

// MARK: - RecordingResult

/// The terminal outcome of a recording session, returned by `RecordingSession.stop()` (AC-9).
///
/// ### Cases
/// - `.completed(SessionOutput, DropHealthSnapshot)` — at least one pipeline produced a file.
/// - `.empty(DropHealthSnapshot)` — stop fired before any sample reached a writer; no files were created.
///
/// ### Independence of writers (AC-9)
/// The two writers finalise in parallel (`async let`); one writer ending in `.failed` does NOT
/// prevent the other from completing.
///
/// ### Invalid-state reduction
/// The `(screen: nil, camera: nil)` combination is unrepresentable in `SessionOutput` —
/// that elimination is enforced inside `SessionOutput`'s failable `init?`.
/// `.empty` names the session-level "no files produced" outcome: `SessionOutput?` is `nil`.
///
/// All members are `nonisolated` so this value type crosses the session-actor boundary as the
/// `stop()` return without an actor hop.
nonisolated enum RecordingResult {
    /// At least one pipeline produced a file; carries per-pipeline outcomes and health snapshot.
    case completed(SessionOutput, DropHealthSnapshot)
    /// No files were produced by this session. Carries a `DropHealthSnapshot` as a transparent
    /// carrier: all-zero / never-degraded on the stop-before-start no-op path; real (possibly
    /// non-zero) counters on the instant-stop path (session ran, no writer produced output).
    case empty(DropHealthSnapshot)

    // MARK: - Drop counters

    /// Cumulative per-reason drop tallies for the whole session (from `DropMonitor.snapshot`).
    nonisolated var drops: DropCounters {
        switch self {
        case let .completed(_, health), let .empty(health):
            health.counters
        }
    }

    /// `true` when the live HUD pill flashed `.degraded` at least once during the session.
    ///
    /// Populated from `DropHealthSnapshot.sessionEverDegraded` — the one-way latch set inside
    /// `DropMonitor.applyDegraded` on the first `.normal → .degraded` transition. This is
    /// intentionally stricter than `drops.encoderBackpressureDrops > 0`: a handful of scattered
    /// backpressure drops spread too thinly to cross the window threshold never trip `.degraded`
    /// and should not trigger the post-stop warning.
    nonisolated var sessionEverDegraded: Bool {
        switch self {
        case let .completed(_, health), let .empty(health):
            health.sessionEverDegraded
        }
    }

    /// The backpressure pipeline stage that accumulated the most drops, or `.notDegraded` if the
    /// session was never degraded. Forwarded from `DropHealthSnapshot.dominantCause`.
    nonisolated var dominantCause: DropCause {
        switch self {
        case let .completed(_, health), let .empty(health):
            health.dominantCause
        }
    }

    // MARK: - Per-pipeline projections

    /// The screen file's finish outcome, or `nil` when the screen pipeline did not run.
    nonisolated var screen: FinishResult? {
        guard case let .completed(output, _) = self else { return nil }
        switch output {
        case let .screenOnly(result), let .both(screen: result, camera: _):
            return result

        case .cameraOnly:
            return nil
        }
    }

    /// The camera file's finish outcome, or `nil` when the camera pipeline did not run.
    nonisolated var camera: FinishResult? {
        guard case let .completed(output, _) = self else { return nil }
        switch output {
        case let .cameraOnly(result), let .both(screen: _, camera: result):
            return result

        case .screenOnly:
            return nil
        }
    }

    /// `true` when the session accumulated enough cumulative encoder-backpressure drops to warrant
    /// the "запись завершена, пропущено N кадров — возможны рывки" post-stop warning (AC-9).
    ///
    /// Only `encoderBackpressureDrops` count — capture / CFR-normalization drops do not warn
    /// (mirrors the `RecordingState.degraded` trigger policy in `DropMonitor`).
    ///
    /// Uses `>= threshold` (inclusive), matching AC-9 spec wording "N ≥ порога". This is distinct
    /// from the live AC-8 sliding-window which uses strict `>` over a short time window — they
    /// measure different things (rate vs session total) and deliberately use different comparisons.
    ///
    /// - Parameter threshold: From `RecordingConfiguration.postStopDropWarningThreshold`.
    nonisolated func degradedWarning(threshold: Int) -> Bool {
        self.drops.encoderBackpressureDrops >= threshold
    }
}

extension RecordingResult {
    /// Convenience: every output URL produced by this session, in screen-then-camera order.
    ///
    /// Empty only in the degenerate case where neither pipeline produced a finish result.
    nonisolated var outputURLs: [URL] {
        var urls: [URL] = []
        if let screenURL = self.screen?.url {
            urls.append(screenURL)
        }
        if let cameraURL = self.camera?.url {
            urls.append(cameraURL)
        }
        return urls
    }

    /// `true` when at least one writer finished as `.failed` (e.g. disk full mid-recording).
    ///
    /// A write failure produces a corrupt or empty file. This flag gates a distinct user-facing
    /// error alert that is separate from — and supersedes — the degraded-drops warning (AC-9),
    /// because the user must know the file was NOT saved cleanly.
    nonisolated var hasWriteFailure: Bool {
        self.screen?.failureError != nil || self.camera?.failureError != nil
    }

    /// A human-readable description of the write failure(s), joining screen and camera reasons
    /// with a newline when both failed. `nil` when `hasWriteFailure` is `false`.
    nonisolated var writeFailureReason: String? {
        guard self.hasWriteFailure else { return nil }
        let reasons = [self.screen?.failureError, self.camera?.failureError]
            .compactMap { $0?.localizedDescription }
        return reasons.joined(separator: "\n")
    }
}
