// MARK: - MenuBarLabelDescriptor

/// Value type describing what the menu-bar label should display in a given moment.
///
/// Produced by `MenuBarLabelMapper` and consumed by `MenuBarLabel`.
/// Separating the mapping from the view makes the mapping independently testable.
struct MenuBarLabelDescriptor: Equatable {
    enum DotStyle: Equatable {
        /// Hollow circle — idle / finished (transient).
        case hollow
        /// Solid red circle — recording normally.
        case red
        /// Solid yellow circle — recording in degraded state.
        case yellow
    }

    /// The SF Symbol name for the dot portion of the label.
    let dotSymbol: String
    /// `true` when the warning triangle should be shown (degraded only).
    let showWarning: Bool
    /// Non-nil when an elapsed timer should appear; `nil` in idle state.
    let elapsed: Int?
}

// MARK: - MenuBarLabelMapper

/// Pure static mapper from coordinator state → `MenuBarLabelDescriptor`.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests without an actor context.
nonisolated enum MenuBarLabelMapper {
    // MARK: - SF Symbol names

    private static let idleSymbol = "circle"
    private static let recordingNormalSymbol = "record.circle.fill"
    private static let recordingDegradedSymbol = "circle.fill"

    // MARK: - Mapping

    /// Maps the current coordinator state to a label descriptor.
    ///
    /// - Phase `.recording` + state `.normal`   → red dot + timer.
    /// - Phase `.recording` + state `.degraded` → yellow dot + warning + timer.
    /// - Any other phase (`.idle`, `.main`, `.finished`) → hollow circle, no timer.
    ///
    /// `.finished` is transient (coordinator moves to `.idle` or `.main` immediately after
    /// reveal). Treating it as idle here is intentional — the hollow circle is shown for one
    /// tick at most, which is acceptable and avoids a stale-timer artifact.
    static func descriptor(
        phase: AppPhase,
        recordingState: RecordingState,
        elapsed: Int
    )
    -> MenuBarLabelDescriptor {
        switch phase {
        case .recording:
            switch recordingState {
            case .normal:
                MenuBarLabelDescriptor(
                    dotSymbol: self.recordingNormalSymbol,
                    showWarning: false,
                    elapsed: elapsed
                )

            case .degraded:
                MenuBarLabelDescriptor(
                    dotSymbol: self.recordingDegradedSymbol,
                    showWarning: true,
                    elapsed: elapsed
                )
            }

        case .idle, .main, .finished:
            MenuBarLabelDescriptor(
                dotSymbol: self.idleSymbol,
                showWarning: false,
                elapsed: nil
            )
        }
    }
}
