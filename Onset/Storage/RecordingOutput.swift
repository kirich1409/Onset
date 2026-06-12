import Foundation

// MARK: - RecordingFileKind

/// Identifies which output file a recorded session writes to.
///
/// The suffix embedded in file names (spec §135) differentiates screen from camera
/// recordings. Both files in a single session share the identical session-start timestamp
/// supplied by the caller; the kind suffix is the only differentiator.
///
/// `Equatable` and `Hashable` conformances are declared inline on the primary type
/// declaration with manual `nonisolated` witnesses. Under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, extension-based conformances for
/// plain-Swift enum types without CoreMedia imports can be inferred `@MainActor` by the
/// test-macro expansion context even when the `==` witness is `nonisolated`. Placing
/// the conformance on the primary declaration forces the witness table to use the
/// `nonisolated` annotation unambiguously. Same pattern as `CFRDropReason` in
/// `CFRNormalizer.swift`.
nonisolated enum RecordingFileKind: Equatable, Hashable {
    /// The screen-capture recording file.
    case screen
    /// The camera-capture recording file.
    case camera

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.screen, .screen),
             (.camera, .camera):
            true

        default:
            false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .screen:
            hasher.combine(0)

        case .camera:
            // Ordinal tag for the second enum case.
            hasher.combine(1)
        }
    }
}

// MARK: - RecordingOutput

/// Pure utility namespace for constructing recording output file paths.
///
/// - Filename format (spec §135): `"Onset YYYY-MM-DD HH.mm.ss — Screen.mp4"` /
///   `"Onset YYYY-MM-DD HH.mm.ss — Camera.mp4"`.
/// - Directory: `~/Movies/Onset/`, created with owner-only permissions on first use.
/// - File permissions: `0o600` (owner read/write) set after `AVAssetWriter` creates the file.
///
/// All methods are `nonisolated` static — no stored state, no actor isolation required.
nonisolated enum RecordingOutput {
    // MARK: - File Naming

    /// Builds the output file name for a recording session.
    ///
    /// - Parameters:
    ///   - timestamp: Session-start timestamp supplied by the caller (#34).
    ///   - kind: Screen or camera.
    /// - Returns: File name including extension, e.g.
    ///   `"Onset 2026-06-04 14.30.05 — Screen.mp4"`.
    nonisolated static func fileName(timestamp: Date, kind: RecordingFileKind) -> String {
        let formatted = Self.makeDateFormatter().string(from: timestamp)
        let suffix = suffix(for: kind)
        return "Onset \(formatted) \(suffix).mp4"
    }

    /// Returns a unique output `URL` inside `directory` for the given session timestamp and kind.
    ///
    /// The base name is built by `fileName(timestamp:kind:)` (spec §135). If the resulting path
    /// already exists — a same-second double-start or a pre-existing file — the method appends a
    /// ` (N)` disambiguator before the `.mp4` extension via `uniqueSlot`, which bounds the search
    /// at 999 attempts and returns the candidate as-is on exhaustion, letting `AVAssetWriter`
    /// surface the error and preserving the one-shot pipeline contract.
    ///
    /// - Parameters:
    ///   - directory: The directory in which the file will be created (e.g. `RecordingOutput.directory()`).
    ///   - timestamp: Session-start timestamp shared by both files of the same session (#198).
    ///   - kind: Screen or camera.
    /// - Returns: A file URL that does not currently exist on disk, or the un-suffixed candidate when
    ///   the disambiguator search is exhausted.
    nonisolated static func uniqueOutputURL(
        in directory: URL,
        timestamp: Date,
        kind: RecordingFileKind
    )
    -> URL {
        let baseName = self.fileName(timestamp: timestamp, kind: kind)
        let baseURL = URL(filePath: baseName, relativeTo: directory)

        // Derive stem and extension via URL path manipulation — avoids NSString bridging.
        let stem = baseURL.deletingPathExtension().lastPathComponent // "Onset YYYY-MM-DD HH.mm.ss — Screen"
        let ext = baseURL.pathExtension // "mp4"

        return Self.uniqueSlot(base: baseURL) { counter in
            URL(filePath: "\(stem) (\(counter)).\(ext)", relativeTo: directory)
        }
    }

    // MARK: - Directory

    /// Returns `~/Movies/Onset/` as a `URL`.
    ///
    /// `FileManager.default.urls(for:in:)` is `@MainActor`-isolated under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `NonisolatedNonsendingByDefault`
    /// and cannot be called from this `nonisolated` static context. The same workaround
    /// used in `RecordingConfiguration.makeMVPDefault()` applies: construct the path via
    /// `NSHomeDirectory()`, which is a plain Foundation free function with no actor isolation.
    nonisolated static func directory() -> URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Movies", directoryHint: .isDirectory)
            .appending(path: "Onset", directoryHint: .isDirectory)
    }

    // MARK: - Directory Permissions

    /// Creates `url` as a directory if absent, with owner-only permissions (`0o700`).
    ///
    /// - Parameter url: The directory URL to create.
    /// - Throws: `CocoaError` if creation or permission-setting fails.
    nonisolated static func ensureDirectory(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        let fileManager = FileManager()

        // Create including intermediate directories; does nothing if already exists.
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)

        // Apply owner-only permissions: rwx------ (0o700).
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path
        )
    }

    // MARK: - File Permissions

    /// Sets owner-read/write-only permissions (`0o600`) on the given file.
    ///
    /// Called by `FileWriter.start(atSourceTime:)` after `AVAssetWriter` creates the file.
    ///
    /// - Parameter url: The file URL to restrict.
    /// - Throws: `CocoaError` if `setAttributes` fails.
    nonisolated static func setOwnerOnly(file url: URL) throws {
        let fileManager = FileManager()
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    // MARK: - Internal helpers

    /// Returns the first URL in the ` (N)` collision series that does not exist on disk.
    ///
    /// Shared by `uniqueOutputURL` (file collision) and `OutputDirectoryNaming.uniqueSessionDirectory`
    /// (directory collision) — both use the same counter range (2…999) and safety-valve semantics.
    ///
    /// - Parameters:
    ///   - base: The unsuffixed candidate URL. Returned immediately if it does not exist.
    ///   - appendSuffix: Closure that builds the ` (N)`-suffixed URL for a given counter value.
    ///     Called with `n` starting at 2, up to 999.
    /// - Returns: The first URL that does not exist on disk; `base` when the range is exhausted.
    nonisolated static func uniqueSlot(
        base: URL,
        appendSuffix: (Int) -> URL
    )
    -> URL {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: base.path(percentEncoded: false)) {
            return base
        }

        // Upper bound avoids an infinite loop; callers surface the error on exhaustion.
        let collisionCounterStart = 2
        let collisionCounterMax = 999
        for counter in collisionCounterStart...collisionCounterMax {
            let candidate = appendSuffix(counter)
            if !fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }

        // Safety valve: return the un-suffixed URL; the caller is responsible for the error.
        return base
    }

    // MARK: - Private helpers

    nonisolated private static func suffix(for kind: RecordingFileKind) -> String {
        switch kind {
        case .screen:
            "— Screen"

        case .camera:
            "— Camera"
        }
    }

    /// Date formatter for the `YYYY-MM-DD HH.mm.ss` component of output paths.
    ///
    /// Shared by `RecordingOutput` (file names) and `OutputDirectoryNaming` (session directory
    /// names) — both use the identical format, locale, and time-zone settings.
    ///
    /// Extracted into a `nonisolated static func` factory — not a `static let` —
    /// because under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `NonisolatedNonsendingByDefault`, a closure literal assigned to a `nonisolated static
    /// let` is still inferred `@MainActor`, making it unusable from nonisolated static
    /// methods. A named function carries `nonisolated` unambiguously (same pattern as
    /// `RecordingConfiguration.makeMVPDefault()`).
    nonisolated static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        // en_US_POSIX: locale-invariant parsing/formatting for file and directory names.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Current system time zone — recording happened local to the user.
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }
}
