// MARK: - MenuBarLabelDescriptor

/// Value type describing what the menu-bar label should display in a given moment.
///
/// Produced by `MenuBarLabelMapper` and consumed by `MenuBarLabel`.
/// Separating the mapping from the view makes the mapping independently testable.
///
/// Layer purity (#154): this descriptor is a semantic token — it carries NO UI-framework type.
/// `DotStyle` encodes the dot's meaning (`hollow`/`red`/`yellow`/`critical`); the view
/// (`MenuBarLabel`) maps that token to a concrete `SwiftUI.Color`. Keeping this file free of
/// `import SwiftUI` lets the mapper depend only on the standard library, matching the other pure
/// types (`AppRouter`, `EffectivePermissions`).
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

        /// `true` only when the warning triangle should appear (degraded state only).
        /// The critical octagon already carries its own exclamation glyph, so no separate triangle.
        var showsWarning: Bool {
            self == .yellow
        }
    }

    /// Encodes the full visual state of the dot (symbol + color + warning flag) as a single enum.
    let dot: DotStyle
    /// Non-nil when an elapsed timer should appear; `nil` in idle state or when the user hid the
    /// menu-bar timer (`showTimer == false`, AC-12a/T-8).
    let elapsed: Int?
    /// `true` when an active capture device was lost mid-recording (#261) — camera unplugged,
    /// lid closed, microphone revoked. Independent of `dot`/`DotStyle.showsWarning`: a source
    /// can vanish while the encoder is still keeping up (`recordingState == .normal`), in which
    /// case `dot` stays `.red` and this flag is the ONLY visible signal in menu-bar-only mode
    /// (recording window not open). The view shows the same warning triangle as backpressure
    /// degradation when either this or `dot.showsWarning` is `true`.
    let deviceLostWarning: Bool
    /// `true` when a low-disk-space warning is active mid-recording (AC-12a, #88, T-8). Mirrors
    /// `deviceLostWarning`'s independence from `dot`/`DotStyle.showsWarning`: free space can drop
    /// below the warn threshold while the encoder is still keeping up, so this is the ONLY visible
    /// signal in menu-bar-only mode. The view shows the same warning triangle for either flag or
    /// `dot.showsWarning`. Clears (de-escalates) as soon as the coordinator's `diskWarning` clears.
    let lowSpaceWarning: Bool
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
    /// Bundles the two independent mid-recording warning signals (device-lost #261, low-space #88)
    /// so `descriptor(...)`/`baselineDescriptor` pass one value instead of four positional params
    /// (keeps `function_parameter_count` under the project limit).
    private struct WarningContext {
        let deviceLost: Bool
        let deviceLostSuffix: String
        let lowSpace: Bool
        let lowSpaceSuffix: String

        init(sourceLiveness: SourceLiveness, diskWarning: DiskWarningReason?) {
            self.deviceLost = !sourceLiveness.screen || !sourceLiveness.camera || !sourceLiveness.microphone
            self.deviceLostSuffix = self.deviceLost ? ", устройство отключено" : ""
            self.lowSpace = diskWarning != nil
            self.lowSpaceSuffix = self.lowSpace ? ", мало места на диске" : ""
        }
    }

    // MARK: - Mapping

    /// Maps the current coordinator state to a label descriptor.
    ///
    /// Precedence while recording: **hard critical > degraded > normal** (spec Severity-модель).
    /// - Phase `.recording` + a HARD `liveCriticalView` → red critical octagon + per-incident a11y,
    ///   regardless of `recordingState` (the indicator must read "fire", not "degraded"). The octagon
    ///   is exclusive of the warning triangle — `deviceLostWarning`/`lowSpaceWarning` are reported
    ///   `false` here so a hard-critical tick never shows octagon + triangle at once.
    /// - Phase `.recording` + SOFT `liveCriticalView` (`cameraAndScreen`) → NO octagon (screen still
    ///   records); the dot follows `recordingState` and only the a11y label updates per spec.
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
    ///   - liveCriticalView: The coordinator's de-escalating windowed-hard / sticky camera-loss view
    ///     (critical-recording-signals). `nil`-defaulted so existing callers/tests are unaffected; the
    ///     live call site passes `coordinator.liveCriticalView`. `cameraOnly` auto-stops the session,
    ///     so its octagon is shown only for the transitional recording tick before `stop()` lands —
    ///     the lasting signal for that case is the post-stop notification (Phase C/E).
    ///   - diskWarning: The coordinator's `diskWarning` state (T-6, AC-12a). Non-`nil` while a
    ///     low-space warning is active mid-recording; `nil` once it de-escalates. Defaults to
    ///     `nil` so idle/main/finished callers and existing call sites need not pass it explicitly.
    static func descriptor(
        phase: AppPhase,
        recordingState: RecordingState,
        elapsed: Int,
        showTimer: Bool,
        sourceLiveness: SourceLiveness = .allLive,
        liveCriticalView: CriticalIncident? = nil,
        diskWarning: DiskWarningReason? = nil
    )
    -> MenuBarLabelDescriptor {
        switch phase {
        case .recording:
            let elapsedField = showTimer ? elapsed : nil
            let context = WarningContext(sourceLiveness: sourceLiveness, diskWarning: diskWarning)
            return Self.recordingDescriptor(
                recordingState: recordingState,
                elapsed: elapsed,
                elapsedField: elapsedField,
                liveCriticalView: liveCriticalView,
                context: context
            )

        case .idle, .main, .finished:
            return MenuBarLabelDescriptor(
                dot: .hollow,
                elapsed: nil,
                deviceLostWarning: false,
                lowSpaceWarning: false,
                accessibilityLabel: "Onset"
            )
        }
    }

    /// The `.recording`-phase branch of `descriptor(...)`, split out to keep that function's body
    /// under the project's `function_body_length` budget.
    ///
    /// Hard critical outranks degraded/normal: renders the octagon + per-incident a11y label.
    /// Device-lost/low-space triangles are suppressed for hard-critical cases — the octagon is the
    /// exclusive signal for that tick (spec AC-11: no dual triangle+octagon).
    private static func recordingDescriptor(
        recordingState: RecordingState,
        elapsed: Int,
        elapsedField: Int?,
        liveCriticalView: CriticalIncident?,
        context: WarningContext
    )
    -> MenuBarLabelDescriptor {
        let elapsedString = ElapsedFormatter.string(from: elapsed)

        switch liveCriticalView {
        case .cameraLost(.cameraOnly):
            return MenuBarLabelDescriptor(
                dot: .critical,
                // Recording has stopped — no live timer (matches the no-<time> spec a11y string).
                elapsed: nil,
                deviceLostWarning: false,
                lowSpaceWarning: false,
                accessibilityLabel: "Onset, критическая ошибка: камера отключена, запись остановлена"
            )

        case .sustainedDrops, .fpsCollapse:
            return MenuBarLabelDescriptor(
                dot: .critical,
                elapsed: elapsedField,
                deviceLostWarning: false,
                lowSpaceWarning: false,
                accessibilityLabel: "Onset, критические потери кадров, \(elapsedString)"
            )

        case .cameraLost(.cameraAndScreen):
            // Soft: no octagon (screen records normally); the dot still follows recordingState,
            // only the a11y label updates per spec.
            return MenuBarLabelDescriptor(
                dot: recordingState == .degraded ? .yellow : .red,
                elapsed: elapsedField,
                deviceLostWarning: context.deviceLost,
                lowSpaceWarning: context.lowSpace,
                accessibilityLabel: "Onset, камера отключена, запись экрана продолжается, \(elapsedString)"
            )

        case nil:
            return Self.baselineDescriptor(
                recordingState: recordingState,
                elapsed: elapsed,
                elapsedField: elapsedField,
                context: context
            )
        }
    }

    /// The non-critical recording descriptor: red dot when `.normal`, yellow + warning when `.degraded`.
    private static func baselineDescriptor(
        recordingState: RecordingState,
        elapsed: Int,
        elapsedField: Int?,
        context: WarningContext
    )
    -> MenuBarLabelDescriptor {
        let elapsedString = ElapsedFormatter.string(from: elapsed)
        switch recordingState {
        case .normal:
            return MenuBarLabelDescriptor(
                dot: .red,
                elapsed: elapsedField,
                deviceLostWarning: context.deviceLost,
                lowSpaceWarning: context.lowSpace,
                accessibilityLabel:
                "Onset, идёт запись\(context.deviceLostSuffix)\(context.lowSpaceSuffix), \(elapsedString)"
            )

        case .degraded:
            return MenuBarLabelDescriptor(
                dot: .yellow,
                elapsed: elapsedField,
                deviceLostWarning: context.deviceLost,
                lowSpaceWarning: context.lowSpace,
                accessibilityLabel:
                "Onset, запись деградирована\(context.deviceLostSuffix)\(context.lowSpaceSuffix), \(elapsedString)"
            )
        }
    }
}
