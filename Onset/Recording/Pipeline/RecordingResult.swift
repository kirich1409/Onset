import Foundation

// MARK: - RecordingResult

/// The terminal outcome of a recording session, assembled by `RecordingSession.stop()` (AC-9).
///
/// Carries the per-file finish outcomes (each is the writer's own `FinishResult` — URL +
/// status), the cumulative drop counters from `DropMonitor`, and a `degradedWarning` flag.
///
/// ### Independence of writers (AC-9)
/// The two writers finalise in parallel (`async let`); one writer ending in `.failed` does NOT
/// prevent the other from completing. Both `screen` and `camera` are optional because a session
/// may run only one pipeline (AC-11) or finalise one early on permission revoke (AC-12) — the
/// surviving pipeline's result is still present.
///
/// All members are `nonisolated` so this value type crosses the session-actor boundary as the
/// `start()` return without an actor hop.
nonisolated struct RecordingResult {
    /// The screen file's finish outcome, or `nil` when the screen pipeline did not run.
    nonisolated let screen: FinishResult?

    /// The camera file's finish outcome, or `nil` when the camera pipeline did not run.
    nonisolated let camera: FinishResult?

    /// Cumulative per-reason drop tallies for the whole session (from `DropMonitor.snapshot`).
    nonisolated let drops: DropCounters

    /// `true` when the session saw enough encoder/disk backpressure drops to warrant the
    /// "запись завершена, пропущено N кадров — возможны рывки" warning (AC-9).
    ///
    /// Computed from `drops.encoderBackpressureDrops > 0` — only backpressure drops degrade the
    /// experience; capture / CFR-normalization drops are tracked but do not warn (mirrors the
    /// `RecordingState.degraded` trigger policy in `DropMonitor`).
    nonisolated let degradedWarning: Bool
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
}

// MARK: - FinishResult URL accessor

extension FinishResult {
    /// The output file URL, available in every terminal case (the path is reserved regardless
    /// of completed / cancelled / failed — see `FinishResult` doc).
    nonisolated var url: URL {
        switch self {
        case let .completed(url),
             let .cancelled(url),
             let .failed(url, _):
            url
        }
    }
}
