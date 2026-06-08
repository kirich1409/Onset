// MARK: - OnboardingFooterDescriptor

/// Describes the footer buttons for a single onboarding state.
///
/// The view renders exactly what the mapper prescribes — one optional graceful link and
/// one primary action — so two enabled buttons with the same action can never appear.
///
/// All stored properties are `nonisolated` so this pure value type can be used from any
/// isolation context without actor hopping (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
struct OnboardingFooterDescriptor {
    // MARK: - Action

    /// The two distinct actions the footer can trigger.
    enum Action {
        /// Navigate to the recording screen (graceful or full).
        case proceed
        /// Re-check the screen-recording permission status now.
        case recheck
    }

    // MARK: - GracefulLink.Style

    /// Visual role of a graceful link: governs its color in the footer.
    enum GracefulLinkStyle {
        /// Escape hatch (gray / `.secondary`) — lets the user leave without granting
        /// anything. Example: "Позже".
        case escape
        /// Graceful feature path (accent color) — proceeds to a limited recording mode.
        /// Example: "Продолжить без экрана", "Записать без звука".
        case feature
    }

    // MARK: - GracefulLink

    /// A secondary plain-text link shown to the left of the primary button.
    struct GracefulLink {
        /// Visible label, e.g. "Записать без звука".
        nonisolated let label: String
        /// The action triggered when the link is tapped.
        nonisolated let action: Action
        /// Visual role: escape hatch (gray) or graceful feature path (accent).
        nonisolated let style: GracefulLinkStyle
    }

    // MARK: - PrimaryButton

    /// The prominent action button shown on the right side of the footer.
    struct PrimaryButton {
        /// Visible label, e.g. "Продолжить".
        nonisolated let label: String
        /// The action triggered when the button is tapped.
        nonisolated let action: Action
        /// When `false` the button is rendered disabled (signpost only — no action fires).
        nonisolated let isEnabled: Bool
    }

    // MARK: - Properties

    /// Optional secondary link shown to the left of the primary button.
    /// `nil` when no graceful-degradation option is available in this state.
    nonisolated let gracefulLink: GracefulLink?

    /// The single primary action button always shown on the right.
    nonisolated let primary: PrimaryButton

    nonisolated init(gracefulLink: GracefulLink? = nil, primary: PrimaryButton) {
        assert(
            gracefulLink.map { !primary.isEnabled || $0.action != primary.action } ?? true,
            "gracefulLink and primary must not both be enabled with the same action"
        )
        self.gracefulLink = gracefulLink
        self.primary = primary
    }
}

// MARK: - Equatable

extension OnboardingFooterDescriptor.Action: Equatable {
    nonisolated static func == (
        lhs: OnboardingFooterDescriptor.Action,
        rhs: OnboardingFooterDescriptor.Action
    )
    -> Bool {
        switch (lhs, rhs) {
        case (.proceed, .proceed), (.recheck, .recheck):
            true

        default:
            false
        }
    }
}

extension OnboardingFooterDescriptor.GracefulLinkStyle: Equatable {
    nonisolated static func == (
        lhs: OnboardingFooterDescriptor.GracefulLinkStyle,
        rhs: OnboardingFooterDescriptor.GracefulLinkStyle
    )
    -> Bool {
        switch (lhs, rhs) {
        case (.escape, .escape), (.feature, .feature):
            true

        default:
            false
        }
    }
}

extension OnboardingFooterDescriptor.GracefulLink: Equatable {}

extension OnboardingFooterDescriptor.PrimaryButton: Equatable {}

extension OnboardingFooterDescriptor: Equatable {}

// MARK: - OnboardingFooterMapper

/// Pure static mapper from onboarding permission state → ``OnboardingFooterDescriptor``.
///
/// `nonisolated` avoids a `MainActor` hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests without an actor context, following the same pattern
/// as `MenuBarLabelMapper` and `AppRouter`.
///
/// ## Decision order (non-awaiting branch)
///
/// 1. `fullModeAvailable` (S+C+M) → "Перейти к записи" (enabled, no link).
/// 2. `!canRecord` (no video source) → disabled "Продолжить" + "Позже" escape link.
/// 3. `cameraOnlyAvailable` (!S+C) → "Продолжить без экрана" (enabled, no link).
///    Checked before the `videoWithoutAudioAvailable` branch so the overlap cell
///    (S=0,C=1,M=0) resolves to the camera-only label, which already describes the mode.
/// 4. `videoWithoutAudioAvailable` (has video, no mic) → disabled "Продолжить" + "Записать без звука" link.
/// 5. Fallback (partial video, mic present) → "Продолжить" (enabled, no link).
nonisolated enum OnboardingFooterMapper {
    // MARK: - Mapping

    /// Computes the footer descriptor for the given permission state.
    ///
    /// - Parameters:
    ///   - isAwaiting: `true` while screen-recording has been requested and polling is in flight.
    ///   - effective: The effective recording permissions derived from the current TCC statuses.
    nonisolated static func descriptor(
        isAwaiting: Bool,
        effective: EffectivePermissions
    )
    -> OnboardingFooterDescriptor {
        if isAwaiting {
            return self.awaitingDescriptor(cameraOnly: effective.cameraOnlyAvailable)
        }
        return self.normalDescriptor(
            canRecord: effective.canRecord,
            cameraOnly: effective.cameraOnlyAvailable,
            noAudio: effective.videoWithoutAudioAvailable,
            fullMode: effective.fullModeAvailable
        )
    }

    // MARK: - Private branches

    nonisolated private static func awaitingDescriptor(
        cameraOnly: Bool
    )
    -> OnboardingFooterDescriptor {
        // Awaiting: "Проверить снова" is always the primary (stays on screen).
        // "Продолжить без экрана" appears as a graceful link only when camera is already
        // available — the user can leave the awaiting state without granting screen.
        let graceful: OnboardingFooterDescriptor.GracefulLink? = cameraOnly
            ? .init(label: "Продолжить без экрана", action: .proceed, style: .feature)
            : nil
        return OnboardingFooterDescriptor(
            gracefulLink: graceful,
            primary: .init(label: "Проверить снова", action: .recheck, isEnabled: true)
        )
    }

    nonisolated private static func normalDescriptor(
        canRecord: Bool,
        cameraOnly: Bool,
        noAudio: Bool,
        fullMode: Bool
    )
    -> OnboardingFooterDescriptor {
        if fullMode {
            // All three granted — single enabled proceed, label signals recording is ready.
            return OnboardingFooterDescriptor(
                primary: .init(label: "Перейти к записи", action: .proceed, isEnabled: true)
            )
        }

        if !canRecord {
            // No video source at all — escape link + disabled proceed signpost.
            // "Позже" lets the user leave without granting anything; main screen blocks recording.
            return OnboardingFooterDescriptor(
                gracefulLink: .init(label: "Позже", action: .proceed, style: .escape),
                primary: .init(label: "Продолжить", action: .proceed, isEnabled: false)
            )
        }

        if cameraOnly {
            // Screen not available, camera is — "Продолжить без экрана" describes the result.
            // Checked before noAudio: the overlap cell (S=0,C=1,M=0) resolves here, not below.
            return OnboardingFooterDescriptor(
                primary: .init(label: "Продолжить без экрана", action: .proceed, isEnabled: true)
            )
        }

        if noAudio {
            // Has video (screen, or screen+camera), mic pending — graceful no-audio path.
            return OnboardingFooterDescriptor(
                gracefulLink: .init(label: "Записать без звука", action: .proceed, style: .feature),
                primary: .init(label: "Продолжить", action: .proceed, isEnabled: false)
            )
        }

        // Partial video + mic present but not full (e.g. S=1 or C=1, M=1, other missing).
        return OnboardingFooterDescriptor(
            primary: .init(label: "Продолжить", action: .proceed, isEnabled: true)
        )
    }
}
