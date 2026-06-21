// MARK: - PostStopAlert

/// Which post-stop alert `MainView` presents after a recording ends.
///
/// `writeError` carries the localized reason for the message body — it is the only post-stop alert
/// remaining: a failed write means the file was not saved, which the user must be told. Frame-loss
/// (dropped frames) is no longer surfaced via an alert; it is persisted as a per-session text
/// technical report next to the recording files (see `RecordingSession.performStop`).
enum PostStopAlert: Identifiable {
    case writeError(reason: String)

    var id: String {
        switch self {
        case .writeError: "writeError"
        }
    }

    /// Returns the post-stop alert given the coordinator state, or `nil` when no alert is due.
    ///
    /// Only the write-error alert remains; this exists as a thin seam so `MainView` keeps a single
    /// alert-resolution entry point and the priority/threading rationale stays in one place.
    ///
    /// - Parameter writeError: Human-readable write-failure reason, or `nil` when the file was saved.
    nonisolated static func resolve(writeError: String?) -> Self? {
        if let reason = writeError {
            return .writeError(reason: reason)
        }
        return nil
    }
}
