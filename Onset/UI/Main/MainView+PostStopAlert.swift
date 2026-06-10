// MARK: - PostStopAlert

/// Which post-stop alert `MainView` presents after a recording ends.
///
/// `writeError` carries the localized reason for the message body.
/// `degradedWarning` carries the session's encoder-backpressure drop count so the alert can
/// display "Пропущено N кадров — возможны рывки." (AC-9).
///
/// Priority ordering is enforced by `resolve(writeError:droppedFrames:threshold:)`: write-error
/// supersedes degraded-warning because a failed write means the file was not saved (higher severity).
enum PostStopAlert: Identifiable {
    case writeError(reason: String)
    /// Post-stop warning shown when encoder-backpressure drops reach `postStopDropWarningThreshold`.
    ///
    /// `droppedFrames` is `RecordingCoordinator.lastDroppedFrames` — frozen at stop time,
    /// reset to 0 in `acknowledgeDegradedWarning()` and on every `start()`.
    case degradedWarning(droppedFrames: Int)

    var id: String {
        switch self {
        case .writeError: "writeError"
        case .degradedWarning: "degradedWarning"
        }
    }

    /// Returns the highest-priority alert given the coordinator state, or `nil` when no alert is due.
    ///
    /// Priority: `.writeError` > `.degradedWarning` > `nil`.
    /// Both flags can be simultaneously true when the writer fails under heavy backpressure;
    /// only the higher-severity alert is shown to avoid competing presentation slots.
    ///
    /// - Parameters:
    ///   - writeError:    Human-readable write-failure reason, or `nil` when the file was saved.
    ///   - droppedFrames: `RecordingCoordinator.lastDroppedFrames` at call time — frozen at stop.
    ///   - threshold:     Minimum cumulative encoder-backpressure drop count that triggers the alert
    ///                    (`RecordingConfiguration.postStopDropWarningThreshold`). Inclusive: `>=`.
    nonisolated static func resolve(writeError: String?, droppedFrames: Int, threshold: Int) -> Self? {
        if let reason = writeError {
            return .writeError(reason: reason)
        }
        if droppedFrames >= threshold {
            return .degradedWarning(droppedFrames: droppedFrames)
        }
        return nil
    }

    /// Localized message for the `.degradedWarning` alert body (AC-9).
    ///
    /// Examples:
    /// - `degradedWarning(droppedFrames: 1).message`  → "Пропущен 1 кадр — возможны рывки."
    /// - `degradedWarning(droppedFrames: 2).message`  → "Пропущено 2 кадра — возможны рывки."
    /// - `degradedWarning(droppedFrames: 5).message`  → "Пропущено 5 кадров — возможны рывки."
    nonisolated var message: String {
        guard case let .degradedWarning(count) = self else { return "" }
        let verb = RussianPluralForm.select(count: count, one: "Пропущен", few: "Пропущено", many: "Пропущено")
        let noun = RussianPluralForm.select(count: count, one: "кадр", few: "кадра", many: "кадров")
        return "\(verb) \(count) \(noun) — возможны рывки."
    }
}
