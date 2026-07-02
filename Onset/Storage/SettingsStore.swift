import Foundation

// MARK: - SettingsDefaults

/// Per-setting default values, applied when a key is absent or holds a non-`Bool` value.
///
/// Single source of truth for the defaults so the `UserDefaults` store and the in-memory
/// double cannot drift apart.
enum SettingsDefaults {
    /// The menu-bar elapsed timer is shown by default — this preserves the pre-Settings
    /// behavior where the menu bar always rendered the timer while recording.
    static let showMenuBarTimer = true

    /// The camera is NOT mirrored by default — the recorded output matches the raw sensor
    /// orientation unless the user opts in.
    static let cameraMirror = false

    /// Camera stabilization is OFF by default (#297) — the stage costs ~30 ms/frame of GPU
    /// work at the reference camera cadence and crops ~1.7% of the image, so it is an
    /// explicit opt-in.
    static let cameraStabilization = false
}

// MARK: - SettingsPersisting

/// Abstracts per-key read/write access to the user-configurable app settings.
///
/// Each setting is persisted under its OWN key (presence-checked, not a JSON blob) so an
/// absent or corrupt key resolves to ITS default without affecting any other setting. Load
/// methods always return a value — never `nil` — folding the default in at the read boundary.
///
/// Conforming types are MainActor-isolated under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting; call sites already on MainActor need
/// no hop.
protocol SettingsPersisting: Sendable {
    /// Returns the persisted "show menu-bar timer" flag, or `SettingsDefaults.showMenuBarTimer`
    /// when the key is absent or holds a non-`Bool` value.
    func loadShowMenuBarTimer() -> Bool

    /// Persists the "show menu-bar timer" flag under its own key.
    func saveShowMenuBarTimer(_ value: Bool)

    /// Returns the persisted "camera mirror" flag, or `SettingsDefaults.cameraMirror` when the
    /// key is absent or holds a non-`Bool` value.
    func loadCameraMirror() -> Bool

    /// Persists the "camera mirror" flag under its own key.
    func saveCameraMirror(_ value: Bool)

    /// Returns the persisted "camera stabilization" flag (#297), or
    /// `SettingsDefaults.cameraStabilization` when the key is absent or holds a non-`Bool` value.
    func loadCameraStabilization() -> Bool

    /// Persists the "camera stabilization" flag under its own key.
    func saveCameraStabilization(_ value: Bool)
}

// MARK: - UserDefaultsSettingsStore

/// Concrete `SettingsPersisting` backed by `UserDefaults`.
///
/// The `defaults` instance is injected at construction time so tests can pass an
/// `InMemoryUserDefaults` without touching the real `~/Library/Preferences/` store.
/// Production code uses the default `UserDefaults.standard`.
///
/// Booleans are stored DIRECTLY via `set(_:forKey:)` (not JSON). Reads use `object(forKey:)`
/// and an `as? Bool` cast rather than `bool(forKey:)`: the latter returns `false` for an
/// absent key, which would make "never set" indistinguishable from "explicitly false" and
/// defeat the per-setting default. A missing or non-`Bool` value resolves to its default.
struct UserDefaultsSettingsStore: SettingsPersisting {
    private let defaults: UserDefaults

    /// Creates a store backed by the given `UserDefaults` instance.
    ///
    /// - Parameter defaults: The `UserDefaults` to read from and write to.
    ///   Production callers omit this parameter to use `.standard`.
    ///
    /// Under a test run, binding to `UserDefaults.standard` traps via `assertionFailure`:
    /// a test that forgot to inject an isolated store would otherwise silently write the
    /// developer's real defaults. Tests must pass an `InMemoryUserDefaults` (see
    /// `ScopedDefaults` / `OnsetTests/CLAUDE.md`).
    init(defaults: UserDefaults = .standard) {
        if isRunningUnderXCTest, defaults === UserDefaults.standard {
            assertionFailure(
                "UserDefaultsSettingsStore bound to UserDefaults.standard under a test run — "
                    + "inject an isolated InMemoryUserDefaults (see ScopedDefaults / OnsetTests/CLAUDE.md)."
            )
        }
        self.defaults = defaults
    }

    /// Reads the menu-bar timer flag, folding in its default for absent/non-`Bool` values.
    func loadShowMenuBarTimer() -> Bool {
        self.loadBool(forKey: SettingsKeys.showMenuBarTimer, default: SettingsDefaults.showMenuBarTimer)
    }

    /// Writes the menu-bar timer flag directly under its key.
    func saveShowMenuBarTimer(_ value: Bool) {
        self.defaults.set(value, forKey: SettingsKeys.showMenuBarTimer)
    }

    /// Reads the camera mirror flag, folding in its default for absent/non-`Bool` values.
    func loadCameraMirror() -> Bool {
        self.loadBool(forKey: SettingsKeys.cameraMirror, default: SettingsDefaults.cameraMirror)
    }

    /// Writes the camera mirror flag directly under its key.
    func saveCameraMirror(_ value: Bool) {
        self.defaults.set(value, forKey: SettingsKeys.cameraMirror)
    }

    /// Reads the camera stabilization flag, folding in its default for absent/non-`Bool` values.
    func loadCameraStabilization() -> Bool {
        self.loadBool(
            forKey: SettingsKeys.cameraStabilization,
            default: SettingsDefaults.cameraStabilization
        )
    }

    /// Writes the camera stabilization flag directly under its key.
    func saveCameraStabilization(_ value: Bool) {
        self.defaults.set(value, forKey: SettingsKeys.cameraStabilization)
    }

    // MARK: - Private helpers

    /// Presence-checked `Bool` read: an absent key (`object(forKey:) == nil`) or a value that is
    /// not a `Bool` resolves to `defaultValue`. This distinguishes "never set" from a stored
    /// `false`, which `bool(forKey:)` cannot.
    private func loadBool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let stored = self.defaults.object(forKey: key) as? Bool else { return defaultValue }
        return stored
    }
}

// MARK: - InMemorySettingsStore

/// In-memory `SettingsPersisting` double for tests and SwiftUI previews.
///
/// Holds the two settings as plain stored `Bool`s — no `UserDefaults`, no persistence across
/// instances. A reference type so a `save` mutates state observable by a later `load` through
/// the same `let`-held store (a struct double held by `let` could not). MainActor-isolated
/// (under the project's default isolation), which makes it `Sendable` without a lock.
final class InMemorySettingsStore: SettingsPersisting {
    private var showMenuBarTimerValue: Bool
    private var cameraMirrorValue: Bool
    private var cameraStabilizationValue: Bool

    /// Creates an in-memory store seeded with the given values (defaults match the production
    /// per-setting defaults).
    init(
        showMenuBarTimer: Bool = SettingsDefaults.showMenuBarTimer,
        cameraMirror: Bool = SettingsDefaults.cameraMirror,
        cameraStabilization: Bool = SettingsDefaults.cameraStabilization
    ) {
        self.showMenuBarTimerValue = showMenuBarTimer
        self.cameraMirrorValue = cameraMirror
        self.cameraStabilizationValue = cameraStabilization
    }

    /// Returns the in-memory menu-bar timer flag.
    func loadShowMenuBarTimer() -> Bool {
        self.showMenuBarTimerValue
    }

    /// Updates the in-memory menu-bar timer flag.
    func saveShowMenuBarTimer(_ value: Bool) {
        self.showMenuBarTimerValue = value
    }

    /// Returns the in-memory camera mirror flag.
    func loadCameraMirror() -> Bool {
        self.cameraMirrorValue
    }

    /// Updates the in-memory camera mirror flag.
    func saveCameraMirror(_ value: Bool) {
        self.cameraMirrorValue = value
    }

    /// Returns the in-memory camera stabilization flag.
    func loadCameraStabilization() -> Bool {
        self.cameraStabilizationValue
    }

    /// Updates the in-memory camera stabilization flag.
    func saveCameraStabilization(_ value: Bool) {
        self.cameraStabilizationValue = value
    }
}
