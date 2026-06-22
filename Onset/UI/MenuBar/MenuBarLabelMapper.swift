import SwiftUI

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
        /// Red filled octagon with an inner exclamation glyph — a hard critical incident is active.
        case critical

        /// The SF Symbol name for this dot state.
        var systemName: String {
            switch self {
            case .hollow: "circle"
            case .red: "record.circle.fill"
            case .yellow: "circle.fill"
            case .critical: "exclamationmark.octagon.fill"
            }
        }

        /// The foreground color for this dot state.
        /// Matches the original `MenuBarLabel.dotColor(for:)` logic exactly:
        /// hollow → .primary (no recording), red → .red, yellow → .yellow.
        /// `critical` is also red — the distinguisher from normal is the INNER glyph (exclamation
        /// vs record dot), not the contour, which at 16–18px reads as a circle (spec AC-11).
        var color: Color {
            switch self {
            case .hollow: .primary
            case .red, .critical: .red
            case .yellow: .yellow
            }
        }

        /// `true` only when the warning triangle should appear (degraded state only).
        /// The critical octagon already carries its own exclamation glyph, so no separate triangle.
        var showsWarning: Bool {
            self == .yellow
        }
    }

    /// Encodes the full visual state of the dot (symbol + color + warning flag) as a single enum.
    let dot: DotStyle
    /// Non-nil when an elapsed timer should appear; `nil` in idle state.
    let elapsed: Int?
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
    /// Precedence while recording: **hard critical > degraded > normal** (spec Severity-модель).
    /// - Phase `.recording` + a HARD `liveCriticalView` → red critical octagon + per-incident a11y,
    ///   regardless of `recordingState` (the indicator must read "fire", not "degraded").
    /// - Phase `.recording` + SOFT `liveCriticalView` (`cameraAndScreen`) → NO octagon (screen still
    ///   records); the dot follows `recordingState` and only the a11y label updates per spec.
    /// - Phase `.recording` + state `.normal`   → red dot + timer.
    /// - Phase `.recording` + state `.degraded` → yellow dot + warning + timer.
    /// - Any other phase (`.idle`, `.main`, `.finished`) → hollow circle, no timer.
    ///
    /// `.finished` is transient (coordinator moves to `.idle` or `.main` immediately after
    /// reveal). Treating it as idle here is intentional — the hollow circle is shown for one
    /// tick at most, which is acceptable and avoids a stale-timer artifact.
    ///
    /// `liveCriticalView` is `nil`-defaulted so existing callers/tests are unaffected; the live call
    /// site passes `coordinator.liveCriticalView` (de-escalating windowed-hard view). `cameraOnly`
    /// auto-stops the session, so its octagon is shown only for the transitional recording tick before
    /// `stop()` lands — the lasting signal for that case is the post-stop notification (Phase C/E).
    static func descriptor(
        phase: AppPhase,
        recordingState: RecordingState,
        elapsed: Int,
        liveCriticalView: CriticalIncident? = nil
    )
    -> MenuBarLabelDescriptor {
        switch phase {
        case .recording:
            let elapsedString = ElapsedFormatter.string(from: elapsed)

            // Hard critical outranks degraded/normal: render the octagon + per-incident a11y label.
            switch liveCriticalView {
            case .cameraLost(.cameraOnly):
                return MenuBarLabelDescriptor(
                    dot: .critical,
                    // Recording has stopped — no live timer (matches the no-<time> spec a11y string).
                    elapsed: nil,
                    accessibilityLabel: "Onset, критическая ошибка: камера отключена, запись остановлена"
                )

            case .sustainedDrops, .fpsCollapse:
                return MenuBarLabelDescriptor(
                    dot: .critical,
                    elapsed: elapsed,
                    accessibilityLabel: "Onset, критические потери кадров, \(elapsedString)"
                )

            case .cameraLost(.cameraAndScreen):
                // Soft: no octagon (screen records normally); the dot still follows recordingState,
                // only the a11y label updates per spec.
                return MenuBarLabelDescriptor(
                    dot: recordingState == .degraded ? .yellow : .red,
                    elapsed: elapsed,
                    accessibilityLabel: "Onset, камера отключена, запись экрана продолжается, \(elapsedString)"
                )

            case nil:
                return Self.baselineDescriptor(recordingState: recordingState, elapsed: elapsed)
            }

        case .idle, .main, .finished:
            return MenuBarLabelDescriptor(dot: .hollow, elapsed: nil, accessibilityLabel: "Onset")
        }
    }

    /// The non-critical recording descriptor: red dot when `.normal`, yellow + warning when `.degraded`.
    private static func baselineDescriptor(
        recordingState: RecordingState,
        elapsed: Int
    )
    -> MenuBarLabelDescriptor {
        let elapsedString = ElapsedFormatter.string(from: elapsed)
        switch recordingState {
        case .normal:
            return MenuBarLabelDescriptor(
                dot: .red,
                elapsed: elapsed,
                accessibilityLabel: "Onset, идёт запись, \(elapsedString)"
            )

        case .degraded:
            return MenuBarLabelDescriptor(
                dot: .yellow,
                elapsed: elapsed,
                accessibilityLabel: "Onset, запись деградирована, \(elapsedString)"
            )
        }
    }
}
