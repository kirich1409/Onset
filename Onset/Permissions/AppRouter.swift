/// The start route for Onset.
///
/// There is no persisted "onboarding completed" flag — routing is always status-driven.
/// The `allSet` case appears at most once per screen-recording grant cycle, driven by
/// the transient `--post-screen-grant` launch argument.
///
/// `Equatable` is implemented manually with `nonisolated` so `Route` can be compared
/// from any isolation context without actor hopping — same pattern as `PermissionStatus`.
enum Route {
    /// Show the onboarding flow (one or more permissions are not yet granted).
    case onboarding
    /// Show the one-time "Всё готово · 3 из 3" screen after a screen-recording relaunch.
    case allSet
    /// Skip onboarding and go directly to the main recording interface.
    case main
}

extension Route: Equatable {
    nonisolated static func == (lhs: Route, rhs: Route) -> Bool {
        switch (lhs, rhs) {
        case (.onboarding, .onboarding),
             (.allSet, .allSet),
             (.main, .main):
            true

        default:
            false
        }
    }
}

/// A pure function that decides the start route from launch context and current permissions.
///
/// **No side effects** — does not read `UserDefaults`, `ProcessInfo`, or call any system API.
/// The composition root (Stage 5) reads those values and passes them in.
///
/// Truth table (AC-5 / AC-8 / AC-9):
///
/// | hasPostScreenGrantArg | screenPreflightGranted | allGranted | → Route     |
/// |-----------------------|------------------------|------------|-------------|
/// | true                  | true                   | any        | .allSet     |
/// | true                  | false                  | any        | status-based (no relaunch — anti-loop) |
/// | false                 | any                    | true       | .main       |
/// | false                 | any                    | false      | .onboarding |
///
/// Note: `allSet` fires when `hasPostScreenGrantArg && screenPreflightGranted`, regardless
/// of camera/microphone status — the spec only requires the relaunch path to confirm screen
/// access. AC-8's "3 из 3" is what the `allSet` screen *shows*, not a precondition for the route.
enum AppRouter {
    /// Computes the start route.
    ///
    /// - Parameters:
    ///   - allGranted: All three permissions (screen + camera + microphone) are `.authorized`.
    ///   - hasPostScreenGrantArg: The process was launched with `--post-screen-grant`.
    ///   - screenPreflightGranted: `CGPreflightScreenCaptureAccess()` is `true` right now.
    nonisolated static func route(
        allGranted: Bool,
        hasPostScreenGrantArg: Bool,
        screenPreflightGranted: Bool
    )
    -> Route {
        if hasPostScreenGrantArg {
            // Relaunch path: anti-loop protection requires preflight to actually be true
            // before showing allSet. If it's still false the grant wasn't picked up yet —
            // fall through to status-based routing without triggering another relaunch.
            if screenPreflightGranted {
                return .allSet
            }
            // hasArg but preflight false → status routing, no loop
        }

        return allGranted ? .main : .onboarding
    }
}

// MARK: - Relaunch trigger predicate

extension AppRouter {
    /// Returns `true` when the running process should trigger a self-relaunch.
    ///
    /// Relaunch is warranted when screen recording was just detected as granted by the
    /// in-process polling loop (i.e. `CGPreflight` flipped to `true` during this run),
    /// and we have not already started a relaunch (anti-loop guard via `pendingFlag`).
    ///
    /// - Parameters:
    ///   - screenJustDetectedGranted: Polling observed `CGPreflightScreenCaptureAccess() == true`.
    ///   - pendingScreenGrantRelaunch: `UserDefaults` flag set before the previous relaunch; signals
    ///     that a relaunch is already in flight — must not trigger again.
    nonisolated static func shouldTriggerRelaunch(
        screenJustDetectedGranted: Bool,
        pendingScreenGrantRelaunch: Bool
    )
    -> Bool {
        screenJustDetectedGranted && !pendingScreenGrantRelaunch
    }
}
