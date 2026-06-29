// MARK: - ControlAvailability

/// Whether a settings control should be interactive, derived purely from its apply-policy and
/// the current recording state.
///
/// Pure classifier output — `nonisolated` so it and its `Equatable` witness are usable from any
/// isolation context under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The view renders
/// `.disabled(…)` plus an explanatory caption from this result; a greyed control always says why.
nonisolated enum ControlAvailability: Equatable {
    /// The control is interactive.
    case enabled

    /// The control is non-interactive (e.g. a recording-affecting setting during an active
    /// recording).
    case disabled
}

extension ControlAvailability {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Under `InferIsolatedConformances`, a synthesised `==` is inferred as `@MainActor`-isolated,
    /// making it unusable from `nonisolated` contexts (and from tests running off the main actor).
    nonisolated static func == (lhs: ControlAvailability, rhs: ControlAvailability) -> Bool {
        switch (lhs, rhs) {
        case (.enabled, .enabled), (.disabled, .disabled):
            true

        default:
            false
        }
    }
}

extension ControlAvailability {
    /// Classifies a control's availability from its apply-policy and whether a recording is active.
    ///
    /// - `.immediate` → always `.enabled` (applies at once; safe to change while recording).
    /// - `.nextRecordingStart` → `.disabled` while a recording is active (the recorded output
    ///   would only change from the next session, so the control is locked mid-recording),
    ///   `.enabled` otherwise.
    ///
    /// - Parameters:
    ///   - policy: When the setting takes effect.
    ///   - isRecordingActive: Whether a recording is currently active (including the start window).
    /// - Returns: `.enabled` or `.disabled`.
    nonisolated static func classify(
        policy: SettingApplyPolicy,
        isRecordingActive: Bool
    )
    -> ControlAvailability {
        switch policy {
        case .immediate:
            .enabled

        case .nextRecordingStart:
            isRecordingActive ? .disabled : .enabled
        }
    }
}
