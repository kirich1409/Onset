// MARK: - ControlAvailability

/// Whether a settings control should be interactive, derived purely from its apply-policy and
/// the current recording state.
///
/// Pure classifier output — `nonisolated` so it and its `Equatable` / `Hashable` witnesses are
/// usable from any isolation context under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The view
/// renders `.disabled(…)` plus an explanatory caption from this result; a greyed control always
/// says why.
nonisolated enum ControlAvailability: Equatable, Hashable {
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
    /// Manual `nonisolated` `Hashable` witness.
    ///
    /// A payload-free enum gets an IMPLICIT `Hashable` synthesis even without an explicit
    /// declaration; under `InferIsolatedConformances` that synthesised `hash(into:)` witness is
    /// inferred `@MainActor`, which makes the type cross into main-actor code from `nonisolated`
    /// contexts. An explicit manual witness overrides it (same pattern as `RecordingState`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .enabled:
            hasher.combine(0)

        case .disabled:
            hasher.combine(1)
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
    /// - `.requiresRelaunch` → always `.enabled` (the value is saved immediately and takes effect
    ///   after a relaunch; it never affects the current recording, so it stays editable). The
    ///   relaunch requirement is communicated separately by the view, not by disabling the control.
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

        case .requiresRelaunch:
            .enabled
        }
    }
}
