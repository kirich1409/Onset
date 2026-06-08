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

    // MARK: - Accessors

    /// The screen file's finish outcome, or `nil` when the screen pipeline did not run.
    nonisolated var screen: FinishResult? {
        switch self {
        case let .screenOnly(result), let .both(screen: result, camera: _):
            result

        case .cameraOnly:
            nil
        }
    }

    /// The camera file's finish outcome, or `nil` when the camera pipeline did not run.
    nonisolated var camera: FinishResult? {
        switch self {
        case let .cameraOnly(result), let .both(screen: _, camera: result):
            result

        case .screenOnly:
            nil
        }
    }
}

// MARK: - RecordingResult

/// The terminal outcome of a recording session, assembled by `RecordingSession.stop()` (AC-9).
///
/// Carries the per-file finish outcomes (each is the writer's own `FinishResult` — URL +
/// status), the cumulative drop counters from `DropMonitor`, and a `degradedWarning` flag.
///
/// ### Independence of writers (AC-9)
/// The two writers finalise in parallel (`async let`); one writer ending in `.failed` does NOT
/// prevent the other from completing.
///
/// ### Invalid-state reduction
/// The `output` field uses `SessionOutput?` instead of independent `screen`/`camera` optionals.
/// When `output` is non-nil, at least one pipeline produced a file — `(screen: nil, camera: nil)`
/// is unrepresentable within `SessionOutput`. `output == nil` remains a reachable degenerate case
/// (stop fired before any writer was created — no samples reached `DualFileOutputStage`).
///
/// All members are `nonisolated` so this value type crosses the session-actor boundary as the
/// `stop()` return without an actor hop.
nonisolated struct RecordingResult {
    /// The per-pipeline file outcomes, or `nil` in the degenerate case where stop was called
    /// before any writer was created (no samples reached `DualFileOutputStage`).
    nonisolated let output: SessionOutput?

    /// Cumulative per-reason drop tallies for the whole session (from `DropMonitor.snapshot`).
    nonisolated let drops: DropCounters

    /// `true` when the session saw enough encoder/disk backpressure drops to warrant the
    /// "запись завершена, пропущено N кадров — возможны рывки" warning (AC-9).
    ///
    /// Computed from `drops.encoderBackpressureDrops > 0` — only backpressure drops degrade the
    /// experience; capture / CFR-normalization drops are tracked but do not warn (mirrors the
    /// `RecordingState.degraded` trigger policy in `DropMonitor`).
    nonisolated let degradedWarning: Bool

    // MARK: - Per-pipeline projections

    /// The screen file's finish outcome, or `nil` when the screen pipeline did not run.
    nonisolated var screen: FinishResult? {
        self.output?.screen
    }

    /// The camera file's finish outcome, or `nil` when the camera pipeline did not run.
    nonisolated var camera: FinishResult? {
        self.output?.camera
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
