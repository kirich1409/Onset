// MARK: - SettingsKeys

/// UserDefaults key constants for per-setting persistence in the Settings window.
///
/// Each setting is stored under its OWN key (not a single JSON blob) so corruption of one key
/// self-heals to its own default without resetting the others. All keys share the
/// `onset.settings.` namespace, intentionally distinct from the `onset.output.` / `onset.device.`
/// / `onset.backend.` families — no legacy keys are reused.
enum SettingsKeys {
    /// Key for the "show elapsed time in the menu bar" toggle (`Bool`).
    /// Absent or non-`Bool` → resolves to `SettingsDefaults.showMenuBarTimer`.
    static let showMenuBarTimer = "onset.settings.showMenuBarTimer"

    /// Key for the "mirror the camera horizontally" toggle (`Bool`).
    /// Absent or non-`Bool` → resolves to `SettingsDefaults.cameraMirror`.
    static let cameraMirror = "onset.settings.cameraMirror"

    /// Key for the last-selected Settings tab (`String`, a `SettingsTab.rawValue`).
    /// Absent or unknown → resolves to `SettingsTab.indication`.
    static let selectedTab = "onset.settings.selectedTab"
}
