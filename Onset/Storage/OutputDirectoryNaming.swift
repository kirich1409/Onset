import Foundation

// MARK: - OutputDirectoryValidation

/// The verdict of a base-directory writability check.
///
/// Returned by `OutputDirectoryNaming.validateBaseDirectory(_:)` so callers can
/// distinguish between the two failure modes and show appropriate UI copy.
///
/// `nonisolated` placement on the primary declaration prevents `InferIsolatedConformances`
/// from inferring `@MainActor` on synthesised witnesses (same pattern as `RecordingState`).
nonisolated enum OutputDirectoryValidation: Equatable {
    /// The directory exists and is writable — recording may proceed.
    case ok // swiftlint:disable:this identifier_name

    /// The path does not exist on disk.
    case doesNotExist

    /// The path exists but the process cannot write to it.
    case notWritable
}

extension OutputDirectoryValidation {
    /// Manual `nonisolated` `Equatable` witness.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `InferIsolatedConformances`,
    /// a synthesised `==` witness is inferred `@MainActor`. Providing an explicit
    /// `nonisolated` override keeps this type usable from actor-isolated and nonisolated
    /// contexts alike (same pattern as `DropReason`).
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ok, .ok),
             (.doesNotExist, .doesNotExist),
             (.notWritable, .notWritable):
            true

        default:
            false
        }
    }
}

// MARK: - OutputDirectoryNaming

/// Pure utility namespace for session-directory naming and base-directory validation.
///
/// ### Session-directory format
/// `"Onset YYYY-MM-DD HH.mm.ss"` — the same timestamp component used in file names
/// (spec §135 / `RecordingOutput.fileName`), so screen and camera file names inside
/// the folder share an unambiguous visual relationship with the folder name.
///
/// ### Collision handling
/// When a same-name directory already exists (same-second double-start or manual
/// pre-existing folder), a ` (N)` suffix is appended at the **folder** level via
/// `RecordingOutput.uniqueSlot`, which bounds the search at 999 attempts.
///
/// All methods are `nonisolated` static — no stored state, no actor isolation required.
nonisolated enum OutputDirectoryNaming {
    // MARK: - Session directory name

    /// Builds the session subdirectory name for the given timestamp.
    ///
    /// - Parameter timestamp: Session-start timestamp (shared with file names).
    /// - Returns: A directory name such as `"Onset 2026-06-12 14.30.05"`.
    nonisolated static func sessionDirectoryName(for timestamp: Date) -> String {
        let formatted = RecordingOutput.makeDateFormatter().string(from: timestamp)
        return "Onset \(formatted)"
    }

    // MARK: - Unique session directory

    /// Returns a unique session-scoped directory URL inside `baseDirectory`.
    ///
    /// The name is built by `sessionDirectoryName(for:)`. If a directory or file with
    /// that name already exists, ` (N)` is appended (starting at 2) via
    /// `RecordingOutput.uniqueSlot`, which bounds the search at 999 attempts. On range
    /// exhaustion, `uniqueSlot` falls back to a UUID-derived suffix so the returned URL
    /// is always free to use — the base candidate is never returned on exhaustion.
    ///
    /// The directory is NOT created by this method — creation is deferred to
    /// `RecordingOutput.ensureDirectory(_:)` at session start.
    ///
    /// - Parameters:
    ///   - baseDirectory: The user-selected (or default) base output directory.
    ///   - timestamp: Session-start timestamp.
    /// - Returns: A directory URL that does not currently exist on disk.
    nonisolated static func uniqueSessionDirectory(
        in baseDirectory: URL,
        timestamp: Date
    )
    -> URL {
        let baseName = Self.sessionDirectoryName(for: timestamp)
        let base = baseDirectory.appending(path: baseName, directoryHint: .isDirectory)

        return RecordingOutput.uniqueSlot(base: base) { counter in
            baseDirectory.appending(path: "\(baseName) (\(counter))", directoryHint: .isDirectory)
        }
    }

    // MARK: - Base directory validation

    /// Checks whether `directory` exists as a directory and is writable.
    ///
    /// Used by `MainViewModel` to gate recording start without a silent fallback.
    /// FileManager access is isolated to this pure function so tests can inject any path.
    ///
    /// A regular file at the given path is treated as `.doesNotExist` — the path is not
    /// a usable output directory even though something occupies it on disk.
    ///
    /// - Parameter directory: The base output directory to validate.
    /// - Returns: An `OutputDirectoryValidation` verdict.
    nonisolated static func validateBaseDirectory(_ directory: URL) -> OutputDirectoryValidation {
        let fileManager = FileManager.default
        let path = directory.path(percentEncoded: false)

        var isDir: ObjCBool = false
        // `fileExists(atPath:isDirectory:)` takes an `UnsafeMutablePointer<ObjCBool>?` — the pointer
        // is scoped to the call duration and does not escape.
        guard unsafe fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            // Either the path does not exist, or it exists but is a regular file — not a directory.
            return .doesNotExist
        }

        guard fileManager.isWritableFile(atPath: path) else {
            return .notWritable
        }

        return .ok
    }
}
