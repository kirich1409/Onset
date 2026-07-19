// MARK: - SettingApplyPolicy

/// Classifies WHEN a changed setting takes effect, so the UI can decide whether a control
/// stays editable during an active recording.
///
/// Pure taxonomy — no framework dependencies. `nonisolated` so it is usable from any isolation
/// context under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — the `ControlAvailability` classifier
/// consumes it (by `switch`) from a `nonisolated` context.
nonisolated enum SettingApplyPolicy {
    /// Applies at once and stays editable while recording (e.g. the menu-bar timer toggle).
    case immediate

    /// Editable any time, but the recorded output is affected only from the next recording
    /// session; the control is locked while a recording is active (e.g. camera mirror).
    case nextRecordingStart
}
