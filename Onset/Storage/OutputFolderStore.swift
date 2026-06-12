import Foundation
import os

// MARK: - Logger

/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated let outputFolderStoreLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "OutputFolderStore"
)

// MARK: - OutputFolderPersisting

/// Persists and retrieves the user-selected base output directory.
///
/// Conforming types are MainActor-isolated under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting; call sites already on
/// MainActor need no hop.
///
/// The default output directory (`~/Movies/Onset/`) is NOT stored by this protocol —
/// callers supply a fallback `URL` when `loadBaseDirectory()` returns `nil`.
protocol OutputFolderPersisting: Sendable {
    /// Persists `url` as the user's chosen base output directory.
    ///
    /// - Parameter url: Absolute path to the chosen directory. The store records the
    ///   `path(percentEncoded: false)` string; no security-scoped bookmark is required
    ///   (Onset runs without App Sandbox).
    func saveBaseDirectory(_ url: URL)

    /// Returns the persisted base directory, or `nil` when no selection has been saved.
    func loadBaseDirectory() -> URL?

    /// Removes the persisted selection, reverting to the default `~/Movies/Onset/` fallback.
    func clearBaseDirectory()
}

// MARK: - UserDefaultsOutputFolderStore

/// Concrete `OutputFolderPersisting` backed by `UserDefaults`.
///
/// The `defaults` instance is injected at construction time so tests can pass an
/// `InMemoryUserDefaults` without touching the real `~/Library/Preferences/` store.
/// Production code uses the default `UserDefaults.standard`.
///
/// The path is stored as a plain `String` — no `NSURL` bookmark needed (no sandbox).
/// A missing or malformed value is treated as "no saved selection" — the store never
/// throws or crashes on bad data.
struct UserDefaultsOutputFolderStore: OutputFolderPersisting {
    private let defaults: UserDefaults

    /// Creates a store backed by the given `UserDefaults` instance.
    ///
    /// - Parameter defaults: The `UserDefaults` to read from and write to.
    ///   Production callers omit this parameter to use `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - OutputFolderPersisting

    /// Encodes `url` as its absolute path string and writes it under `OutputFolderKeys.baseDirectory`.
    func saveBaseDirectory(_ url: URL) {
        let path = url.path(percentEncoded: false)
        self.defaults.set(path, forKey: OutputFolderKeys.baseDirectory)
        // Path is not logged — it contains the user's home directory (PII, issue #188).
        outputFolderStoreLogger.info("Output base directory saved")
    }

    /// Decodes and returns the saved base directory, or `nil` on missing or unresolvable data.
    func loadBaseDirectory() -> URL? {
        guard let path = self.defaults.string(forKey: OutputFolderKeys.baseDirectory),
              !path.isEmpty
        else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Removes the base directory selection from `UserDefaults`.
    func clearBaseDirectory() {
        self.defaults.removeObject(forKey: OutputFolderKeys.baseDirectory)
    }
}
