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
/// pre-existing folder), a ` (N)` suffix is appended at the **folder** level and
/// incremented until a free slot is found. The search is bounded at 999 attempts.
///
/// All methods are `nonisolated` static — no stored state, no actor isolation required.
nonisolated enum OutputDirectoryNaming {
    // MARK: - Session directory name

    /// Builds the session subdirectory name for the given timestamp.
    ///
    /// - Parameter timestamp: Session-start timestamp (shared with file names).
    /// - Returns: A directory name such as `"Onset 2026-06-12 14.30.05"`.
    nonisolated static func sessionDirectoryName(for timestamp: Date) -> String {
        let formatted = Self.makeDateFormatter().string(from: timestamp)
        return "Onset \(formatted)"
    }

    // MARK: - Unique session directory

    /// Returns a unique session-scoped directory URL inside `baseDirectory`.
    ///
    /// The name is built by `sessionDirectoryName(for:)`. If a directory or file with
    /// that name already exists, ` (N)` is appended (starting at 2) and incremented until
    /// a free slot is found. After 999 attempts the un-suffixed candidate is returned and
    /// the caller is responsible for any downstream error.
    ///
    /// The directory is NOT created by this method — creation is deferred to
    /// `RecordingOutput.ensureDirectory(_:)` at session start.
    ///
    /// - Parameters:
    ///   - baseDirectory: The user-selected (or default) base output directory.
    ///   - timestamp: Session-start timestamp.
    /// - Returns: A directory URL that does not currently exist on disk, or the
    ///   un-suffixed candidate when the search is exhausted.
    nonisolated static func uniqueSessionDirectory(
        in baseDirectory: URL,
        timestamp: Date
    )
    -> URL {
        let baseName = Self.sessionDirectoryName(for: timestamp)
        let fileManager = FileManager()

        let candidate = baseDirectory.appending(path: baseName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            return candidate
        }

        let collisionCounterStart = 2
        let collisionCounterMax = 999
        for counter in collisionCounterStart...collisionCounterMax {
            let suffixed = "\(baseName) (\(counter))"
            let suffixedURL = baseDirectory.appending(path: suffixed, directoryHint: .isDirectory)
            if !fileManager.fileExists(atPath: suffixedURL.path(percentEncoded: false)) {
                return suffixedURL
            }
        }

        // Safety valve: return the un-suffixed URL; downstream creation will fail and surface the error.
        return candidate
    }

    // MARK: - Base directory validation

    /// Checks whether `directory` exists and is writable.
    ///
    /// Used by `MainViewModel` to gate recording start without a silent fallback.
    /// FileManager access is isolated to this pure function so tests can inject any path.
    ///
    /// - Parameter directory: The base output directory to validate.
    /// - Returns: An `OutputDirectoryValidation` verdict.
    nonisolated static func validateBaseDirectory(_ directory: URL) -> OutputDirectoryValidation {
        let fileManager = FileManager()
        let path = directory.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: path) else {
            return .doesNotExist
        }

        guard fileManager.isWritableFile(atPath: path) else {
            return .notWritable
        }

        return .ok
    }

    // MARK: - Private helpers

    /// Date formatter for the `YYYY-MM-DD HH.mm.ss` component of the session directory name.
    ///
    /// Extracted into a `nonisolated private static func` factory — not a `static let` —
    /// because under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `NonisolatedNonsendingByDefault`, a closure literal assigned to a `nonisolated static let`
    /// is still inferred `@MainActor`. A named function carries `nonisolated` unambiguously
    /// (same pattern as `RecordingOutput.makeDateFormatter()`).
    nonisolated private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        // en_US_POSIX: locale-invariant formatting for directory names.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Current system time zone — recording happened local to the user.
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }
}
