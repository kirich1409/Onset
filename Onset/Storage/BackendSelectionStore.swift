import Foundation
import os

// MARK: - Logger

/// Sendable; nonisolated avoids a MainActor hop under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated let backendSelectionStoreLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "BackendSelectionStore"
)

// MARK: - BackendSelectionPersisting

/// Abstracts read/write access to the persisted recording-backend selection.
///
/// Conforming types are responsible for encoding, decoding, and storing a single
/// `PersistedBackendSelection` blob. Conforming types are MainActor-isolated under
/// the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting; call sites already
/// on MainActor need no hop, off-actor callers cross one.
protocol BackendSelectionPersisting: Sendable {
    /// Persists `selection` as a single JSON blob, replacing any prior value.
    func save(_ selection: PersistedBackendSelection)

    /// Returns the most recently persisted backend selection, or `nil` if absent or corrupt.
    func load() -> PersistedBackendSelection?

    /// Removes the persisted backend selection.
    func clear()
}

// MARK: - UserDefaultsBackendSelectionStore

/// Concrete `BackendSelectionPersisting` backed by `UserDefaults`.
///
/// The `defaults` instance is injected at construction time so tests can pass an
/// `InMemoryUserDefaults` without touching the real `~/Library/Preferences/` store.
/// Production code uses the default `UserDefaults.standard`.
///
/// The entire `PersistedBackendSelection` is JSON-encoded via `Codable` and stored
/// under a single key (`BackendSelectionKeys.selection`). A corrupt or missing blob
/// is treated as "no saved selection" — the store never throws or crashes on bad data.
struct UserDefaultsBackendSelectionStore: BackendSelectionPersisting {
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
                "UserDefaultsBackendSelectionStore bound to UserDefaults.standard under a test run — "
                    + "inject an isolated InMemoryUserDefaults (see ScopedDefaults / OnsetTests/CLAUDE.md)."
            )
        }
        self.defaults = defaults
    }

    /// Encodes `selection` as JSON and writes it under `BackendSelectionKeys.selection`.
    func save(_ selection: PersistedBackendSelection) {
        self.saveValue(selection, forKey: BackendSelectionKeys.selection)
    }

    /// Decodes and returns the saved backend selection, or `nil` on missing/corrupt data.
    ///
    /// Returns `nil` (not a crash) on corrupt or legacy-format blobs. The self-heal path
    /// purges the corrupt blob so the caller receives `nil` on the next load, allowing the
    /// resolver to apply its default (`.live`) fallback for all stages.
    func load() -> PersistedBackendSelection? {
        self.loadValue(forKey: BackendSelectionKeys.selection)
    }

    /// Removes the backend selection blob from `UserDefaults`.
    func clear() {
        self.defaults.removeObject(forKey: BackendSelectionKeys.selection)
    }

    // MARK: - Private helpers

    private func saveValue(_ value: some Encodable, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            self.defaults.set(data, forKey: key)
        } catch {
            backendSelectionStoreLogger.error(
                "Failed to encode backend selection for key '\(key)': \(String(describing: error))"
            )
        }
    }

    private func loadValue<T: Decodable>(forKey key: String) -> T? {
        guard let data = self.defaults.object(forKey: key) as? Data else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            backendSelectionStoreLogger.error(
                "Failed to decode backend selection for key '\(key)': \(String(describing: error))"
            )
            // Self-heal: purge the corrupt blob so the next launch starts clean.
            self.defaults.removeObject(forKey: key)
            backendSelectionStoreLogger.notice("Purged corrupt backend selection blob for key '\(key)'")
            return nil
        }
    }
}
