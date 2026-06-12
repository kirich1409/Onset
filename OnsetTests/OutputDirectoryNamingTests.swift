import Foundation
@testable import Onset
import Testing

// MARK: - OutputDirectoryNamingTests

/// L2 tests for the pure `OutputDirectoryNaming` utility and `OutputDirectoryValidation`.
///
/// Covers:
/// 1. Session directory name format: `"Onset YYYY-MM-DD HH.mm.ss"` for a fixed timestamp.
/// 2. Collision-free path: no existing folder → returns the base candidate.
/// 3. Collision ` (2)`: one existing folder → returns the `(2)` suffix.
/// 4. Multiple collisions: several existing folders → suffix increments to `(N)`.
/// 5. Validation `.ok`: existing, writable directory.
/// 6. Validation `.doesNotExist`: path that has never been created.
/// 7. Validation `.notWritable`: existing directory with write permission removed.
/// 8. `OutputDirectoryValidation.==` — equatable cases.
///
/// All filesystem operations use `FileManager.default` on `FileManager.temporaryDirectory`
/// — no home-directory paths leak into any assertion or log.
@Suite("OutputDirectoryNaming — pure naming + validation logic")
struct OutputDirectoryNamingTests {
    // MARK: - Helpers

    /// Unique temporary directory for a single test; caller is responsible for cleanup.
    private func makeTemporaryBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "onset-naming-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Fixed reference timestamp: 2026-06-12 14:30:05 (system time zone).
    private func referenceDate() throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = 14
        components.minute = 30
        components.second = 5
        components.timeZone = TimeZone.current
        return try #require(Calendar(identifier: .gregorian).date(from: components))
    }

    // MARK: - Session directory name

    /// The session directory name must match `"Onset YYYY-MM-DD HH.mm.ss"` with dots
    /// separating time components (spec §135 alignment with file-name format).
    @Test("sessionDirectoryName matches expected format for a fixed timestamp")
    func sessionDirectoryName_matchesExpectedFormat() throws {
        let name = try OutputDirectoryNaming.sessionDirectoryName(for: self.referenceDate())
        #expect(name == "Onset 2026-06-12 14.30.05")
    }

    /// Year, month, and day fields must be zero-padded.
    @Test("sessionDirectoryName zero-pads single-digit month and day")
    func sessionDirectoryName_zeropadsMonthAndDay() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 5
        components.hour = 9
        components.minute = 3
        components.second = 7
        components.timeZone = TimeZone.current
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        let name = OutputDirectoryNaming.sessionDirectoryName(for: date)
        #expect(name == "Onset 2026-01-05 09.03.07")
    }

    // MARK: - Unique session directory — no collision

    /// When no folder with the candidate name exists, `uniqueSessionDirectory` returns
    /// the un-suffixed base candidate.
    @Test("uniqueSessionDirectory returns base candidate when no collision exists")
    func uniqueSessionDirectory_noCandidateExists_returnsBaseCandidate() throws {
        let base = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try OutputDirectoryNaming.uniqueSessionDirectory(
            in: base,
            timestamp: self.referenceDate()
        )

        let expected = base.appending(path: "Onset 2026-06-12 14.30.05", directoryHint: .isDirectory)
        #expect(result.path(percentEncoded: false) == expected.path(percentEncoded: false))
    }

    // MARK: - Unique session directory — single collision

    /// When the base candidate already exists, the result must be the `(2)` variant.
    @Test("uniqueSessionDirectory suffixes (2) when base candidate already exists")
    func uniqueSessionDirectory_baseCandidateExists_returnsSuffixed2() throws {
        let base = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Create the un-suffixed folder so it collides.
        let existing = base.appending(path: "Onset 2026-06-12 14.30.05", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)

        let result = try OutputDirectoryNaming.uniqueSessionDirectory(
            in: base,
            timestamp: self.referenceDate()
        )

        let expected = base.appending(
            path: "Onset 2026-06-12 14.30.05 (2)",
            directoryHint: .isDirectory
        )
        #expect(result.path(percentEncoded: false) == expected.path(percentEncoded: false))
    }

    // MARK: - Unique session directory — multiple collisions

    /// When the base candidate AND `(2)` both exist, the result must be the `(3)` variant.
    @Test("uniqueSessionDirectory increments suffix past (2) when both candidates exist")
    func uniqueSessionDirectory_twoCollisions_returnsSuffixed3() throws {
        let base = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let baseName = "Onset 2026-06-12 14.30.05"
        let names = [baseName, "\(baseName) (2)"]
        for name in names {
            try FileManager.default.createDirectory(
                at: base.appending(path: name, directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
        }

        let result = try OutputDirectoryNaming.uniqueSessionDirectory(
            in: base,
            timestamp: self.referenceDate()
        )

        let expected = base.appending(
            path: "\(baseName) (3)",
            directoryHint: .isDirectory
        )
        #expect(result.path(percentEncoded: false) == expected.path(percentEncoded: false))
    }

    // MARK: - Validation — ok

    /// An existing, writable directory must return `.ok`.
    @Test("validateBaseDirectory returns .ok for an existing writable directory")
    func validateBaseDirectory_existingWritable_returnsOk() throws {
        let dir = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: dir) }

        let verdict = OutputDirectoryNaming.validateBaseDirectory(dir)
        #expect(verdict == .ok)
    }

    // MARK: - Validation — does not exist

    /// A path that has never been created must return `.doesNotExist`.
    @Test("validateBaseDirectory returns .doesNotExist for a non-existent path")
    func validateBaseDirectory_nonExistentPath_returnsDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "onset-nonexistent-\(UUID().uuidString)", directoryHint: .isDirectory)

        let verdict = OutputDirectoryNaming.validateBaseDirectory(missing)
        #expect(verdict == .doesNotExist)
    }

    // MARK: - Validation — not writable

    /// A directory whose write permission bit has been cleared must return `.notWritable`.
    ///
    /// Permissions are restored in `defer` to avoid polluting the temp directory.
    @Test("validateBaseDirectory returns .notWritable when write bit is cleared")
    func validateBaseDirectory_readOnlyDirectory_returnsNotWritable() throws {
        let dir = try makeTemporaryBase()
        defer {
            // Restore write permission so the directory can be cleaned up.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path())
            try? FileManager.default.removeItem(at: dir)
        }

        // Remove write permission (owner: r-x, group: r-x, other: r-x).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dir.path()
        )

        let verdict = OutputDirectoryNaming.validateBaseDirectory(dir)
        #expect(verdict == .notWritable)
    }

    // MARK: - OutputDirectoryValidation equatable

    /// `.ok == .ok`, `.doesNotExist == .doesNotExist`, `.notWritable == .notWritable`.
    @Test("OutputDirectoryValidation equality — matching cases")
    func outputDirectoryValidation_equality_matchingCases() {
        #expect(OutputDirectoryValidation.ok == .ok)
        #expect(OutputDirectoryValidation.doesNotExist == .doesNotExist)
        #expect(OutputDirectoryValidation.notWritable == .notWritable)
    }

    /// Distinct cases must not be equal.
    @Test("OutputDirectoryValidation equality — distinct cases are unequal")
    func outputDirectoryValidation_equality_distinctCasesAreUnequal() {
        #expect(OutputDirectoryValidation.ok != .doesNotExist)
        #expect(OutputDirectoryValidation.ok != .notWritable)
        #expect(OutputDirectoryValidation.doesNotExist != .notWritable)
    }

    // MARK: - uniqueSlot exhaustion — UUID fallback

    /// When `appendSuffix` always returns an occupied path, `uniqueSlot` must fall back to a
    /// UUID-suffixed URL that does not equal `base` and does not exist on disk.
    ///
    /// This test drives `RecordingOutput.uniqueSlot` directly, passing a closure that always
    /// reports the candidate as occupied (by pre-creating it), so the 2…999 range is exhausted
    /// without actually creating 998 directories.
    @Test("uniqueSlot falls back to UUID suffix when appendSuffix always yields an occupied path")
    func uniqueSlot_appendSuffixAlwaysOccupied_returnsUniqueURL() throws {
        let base = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Pre-create the base path so uniqueSlot enters the collision branch.
        let occupied = base.appending(path: "slot-base", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        // appendSuffix: each call creates the candidate and returns it — all counters occupied.
        let result = RecordingOutput.uniqueSlot(base: occupied) { counter in
            let candidate = base.appending(
                path: "slot-base (\(counter))",
                directoryHint: .isDirectory
            )
            // Create so fileExists returns true for this counter.
            try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            return candidate
        }

        #expect(result != occupied, "must not return the occupied base on exhaustion")
        #expect(
            !FileManager.default.fileExists(atPath: result.path(percentEncoded: false)),
            "UUID fallback must not yet exist on disk"
        )
    }

    // MARK: - Validation — file at path is treated as .doesNotExist

    /// A regular file at the given path must return `.doesNotExist` — a file is not a
    /// usable output directory even though `fileExists(atPath:)` would return `true`.
    @Test("validateBaseDirectory returns .doesNotExist when the path is a regular file")
    func validateBaseDirectory_regularFile_returnsDoesNotExist() throws {
        let base = try makeTemporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // Create a regular file (not a directory) at the candidate path.
        let filePath = base.appending(path: "onset-file-\(UUID().uuidString)")
        FileManager.default.createFile(
            atPath: filePath.path(percentEncoded: false),
            contents: nil
        )

        let verdict = OutputDirectoryNaming.validateBaseDirectory(filePath)
        #expect(verdict == .doesNotExist, "a regular file must be treated as .doesNotExist")
    }
}
