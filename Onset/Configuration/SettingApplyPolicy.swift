// MARK: - SettingApplyPolicy

/// Classifies WHEN a changed setting takes effect, so the UI can decide whether a control
/// stays editable during an active recording.
///
/// Pure taxonomy — no framework dependencies. `nonisolated` so the value and its `Equatable` /
/// `Hashable` witnesses are usable from any isolation context under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (the `ControlAvailability` classifier consumes it
/// from a `nonisolated` context).
nonisolated enum SettingApplyPolicy: Equatable, Hashable {
    /// Applies at once and stays editable while recording (e.g. the menu-bar timer toggle).
    case immediate

    /// Editable any time, but the recorded output is affected only from the next recording
    /// session; the control is locked while a recording is active (e.g. camera mirror).
    case nextRecordingStart

    /// Saved immediately but only takes effect after an app relaunch. Defined for
    /// forward-compatibility; unused in v1.
    case requiresRelaunch
}

extension SettingApplyPolicy {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Under `InferIsolatedConformances`, a synthesised `==` is inferred as `@MainActor`-isolated,
    /// making it unusable from `nonisolated` contexts such as the `ControlAvailability` classifier.
    nonisolated static func == (lhs: SettingApplyPolicy, rhs: SettingApplyPolicy) -> Bool {
        switch (lhs, rhs) {
        case (.immediate, .immediate),
             (.nextRecordingStart, .nextRecordingStart),
             (.requiresRelaunch, .requiresRelaunch):
            true

        default:
            false
        }
    }
}

extension SettingApplyPolicy {
    /// Manual `nonisolated` `Hashable` witness.
    ///
    /// A payload-free enum gets an IMPLICIT `Hashable` synthesis even without an explicit
    /// declaration; under `InferIsolatedConformances` that synthesised `hash(into:)` witness is
    /// inferred `@MainActor`, which makes the type cross into main-actor code from `nonisolated`
    /// contexts. An explicit manual witness overrides it (same pattern as `RecordingState`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .immediate:
            hasher.combine(0)

        case .nextRecordingStart:
            hasher.combine(1)

        case .requiresRelaunch:
            // Ordinal tag for the third enum case; 2 is not in no_magic_numbers' exempt list.
            // swiftlint:disable:next no_magic_numbers
            hasher.combine(2)
        }
    }
}
