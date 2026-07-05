// MARK: - MenuBarLabelDescriptor

/// Value type describing what the menu-bar label should display in a given moment.
///
/// Produced by `MenuBarLabelMapper` and consumed by `MenuBarLabel`.
/// Separating the mapping from the view makes the mapping independently testable.
///
/// Layer purity (#154): this descriptor is a semantic token — it carries NO UI-framework type.
/// `DotStyle` encodes the dot's meaning (`hollow`/`red`/`yellow`); the view (`MenuBarLabel`) maps
/// that token to a concrete `SwiftUI.Color`. Keeping this file free of `import SwiftUI` lets the
/// mapper depend only on the standard library, matching the other pure types (`AppRouter`,
/// `EffectivePermissions`).
struct MenuBarLabelDescriptor: Equatable {
    enum DotStyle: Equatable {
        /// Hollow circle — idle / finished (transient).
        case hollow
        /// Solid red circle — recording normally.
        case red
        /// Solid yellow circle — recording in degraded state.
        case yellow

        /// The SF Symbol name for this dot state.
        var systemName: String {
            switch self {
            case .hollow: "circle"
            case .red: "record.circle.fill"
            case .yellow: "circle.fill"
            }
        }

        /// `true` only when the warning triangle should appear (degraded state only).
        var showsWarning: Bool {
            self == .yellow
        }
    }

    /// Encodes the full visual state of the dot (symbol + color + warning flag) as a single enum.
    let dot: DotStyle
    /// Non-nil when an elapsed timer should appear; `nil` in idle state.
    let elapsed: Int?
    /// `true` when an active capture device was lost mid-recording (#261) — camera unplugged,
    /// lid closed, microphone revoked. Independent of `dot`/`DotStyle.showsWarning`: a source
    /// can vanish while the encoder is still keeping up (`recordingState == .normal`), in which
    /// case `dot` stays `.red` and this flag is the ONLY visible signal in menu-bar-only mode
    /// (recording window not open). The view shows the same warning triangle as backpressure
    /// degradation when either this or `dot.showsWarning` is `true`.
    let deviceLostWarning: Bool
    /// VoiceOver label for the status-item button (#242). Describes the current recording state
    /// and elapsed time so screen-reader users receive the same information as sighted users.
    let accessibilityLabel: String
}

// MARK: - MenuBarLabelMapper

/// Pure static mapper from coordinator state → `MenuBarLabelDescriptor`.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests without an actor context.
nonisolated enum MenuBarLabelMapper {
    // MARK: - Mapping

    /// Maps the current coordinator state to a label descriptor.
    ///
    /// - Phase `.recording` + state `.normal`   → red dot + timer (when `showTimer`).
    /// - Phase `.recording` + state `.degraded` → yellow dot + warning + timer (when `showTimer`).
    /// - Any other phase (`.idle`, `.main`, `.finished`) → hollow circle, no timer.
    ///
    /// `.finished` is transient (coordinator moves to `.idle` or `.main` immediately after
    /// reveal). Treating it as idle here is intentional — the hollow circle is shown for one
    /// tick at most, which is acceptable and avoids a stale-timer artifact.
    ///
    /// - Parameters:
    ///   - showTimer: When `false`, the descriptor's `elapsed` is `nil` so the visible
    ///     time string is suppressed (the «Показывать таймер» setting). The status dot is
    ///     independent of this flag — recording is still signalled, only the time is hidden. The
    ///     `accessibilityLabel` keeps the spoken elapsed time so VoiceOver users still hear the
    ///     recording duration regardless of the visible-timer preference.
    ///   - sourceLiveness: Per-source liveness from `RecordingCoordinator` (#261). Any `false`
    ///     field while `phase == .recording` means a capture device dropped mid-recording — this
    ///     drives `deviceLostWarning` regardless of `recordingState`, since a device loss does not
    ///     necessarily produce encoder backpressure. Defaults to `.allLive` so idle/main/finished
    ///     callers and existing call sites need not pass it explicitly.
    static func descriptor(
        phase: AppPhase,
        recordingState: RecordingState,
        elapsed: Int,
        showTimer: Bool,
        sourceLiveness: SourceLiveness = .allLive
    )
    -> MenuBarLabelDescriptor {
        switch phase {
        case .recording:
            let elapsedString = ElapsedFormatter.string(from: elapsed)
            let elapsedField = showTimer ? elapsed : nil
            let deviceLost = !sourceLiveness.screen || !sourceLiveness.camera || !sourceLiveness.microphone
            let deviceLostSuffix = deviceLost ? ", устройство отключено" : ""
            switch recordingState {
            case .normal:
                return MenuBarLabelDescriptor(
                    dot: .red,
                    elapsed: elapsedField,
                    deviceLostWarning: deviceLost,
                    accessibilityLabel: "Onset, идёт запись\(deviceLostSuffix), \(elapsedString)"
                )

            case .degraded:
                return MenuBarLabelDescriptor(
                    dot: .yellow,
                    elapsed: elapsedField,
                    deviceLostWarning: deviceLost,
                    accessibilityLabel: "Onset, запись деградирована\(deviceLostSuffix), \(elapsedString)"
                )
            }

        case .idle, .main, .finished:
            return MenuBarLabelDescriptor(
                dot: .hollow,
                elapsed: nil,
                deviceLostWarning: false,
                accessibilityLabel: "Onset"
            )
        }
    }
}
