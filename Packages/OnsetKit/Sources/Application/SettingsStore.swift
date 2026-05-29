import Foundation

// MARK: - SettingsStore

/// Persists and vends user recording preferences.
///
/// `actor` isolation ensures Sendable conformance so that the store can be safely
/// injected into `RecordingSessionCoordinator` (also an actor) across the concurrency
/// boundary — a plain `class` would require `@unchecked Sendable`, which the project bans.
///
/// Inject `UserDefaults` via the initializer for testability. The store never reaches
/// `UserDefaults.standard` internally; the caller owns that seam.
///
/// - Note: Full draft-`Selections` persistence is deferred to issue #30/#31.
///   When `Selections` lands, add typed getters/setters here against the injected `defaults`.
public actor SettingsStore {

    // MARK: Dependencies

    /// The backing key-value store. Injected via init — never accessed as a global singleton
    /// inside method bodies (AC: no hidden-singleton access).
    private let defaults: UserDefaults

    // MARK: Initializer

    /// Creates a `SettingsStore` backed by the given `UserDefaults` instance.
    ///
    /// - Parameter defaults: The `UserDefaults` to read and write settings from.
    ///   Pass a suite-namespaced instance in tests (`UserDefaults(suiteName:)`) to isolate
    ///   test state from the application's real preferences store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Seam — Selections persistence (#30/#31)
    //
    // TODO(#30/#31): When `Selections` is defined, expose typed read/write methods here,
    // e.g.:
    //   func selections() -> Selections { ... }
    //   func save(_ selections: Selections) { ... }
    //
    // Encode/decode via `defaults` using Codable + `PropertyListEncoder` or dedicated keys.
}
