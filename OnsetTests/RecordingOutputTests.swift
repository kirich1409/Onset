import Foundation
@testable import Onset
import Testing

// MARK: - RecordingFileKindTests

@Suite("RecordingFileKind — Equatable")
struct RecordingFileKindTests {
    @Test("screen is equal to another .screen value (reflexivity)")
    func screenEquality() {
        let lhs = RecordingFileKind.screen
        let rhs = RecordingFileKind.screen
        #expect(lhs == rhs)
    }

    @Test("camera is equal to another .camera value (reflexivity)")
    func cameraEquality() {
        let lhs = RecordingFileKind.camera
        let rhs = RecordingFileKind.camera
        #expect(lhs == rhs)
    }

    @Test("screen != camera")
    func screenNotEqualCamera() {
        #expect(RecordingFileKind.screen != RecordingFileKind.camera)
    }
}

// MARK: - RecordingOutputFileNameTests

@Suite("RecordingOutput.fileName")
struct RecordingOutputFileNameTests {
    /// Fixed test date: 2026-06-04 14:30:05 local.
    ///
    /// Uses `TimeIntervalSince1970` directly — avoids force-unwrapping `Calendar.date(from:)`.
    /// The timestamp 1_749_038_205 is 2026-06-04 14:30:05 UTC; local-timezone offset does not
    /// affect the test because `RecordingOutput.fileName` uses `TimeZone.current` in the same way.
    private var testDate: Date {
        Date(timeIntervalSince1970: 1_749_038_205)
    }

    @Test("screen filename format matches spec §135")
    func screenFileName() {
        let name = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        // Verify prefix, extension, and screen suffix.
        #expect(name.hasPrefix("Onset "))
        #expect(name.hasSuffix("— Screen.mp4"))
        // Date component is between "Onset " and " — Screen.mp4".
        let dateComponent = name
            .dropFirst("Onset ".count)
            .dropLast(" — Screen.mp4".count)
        // Format: YYYY-MM-DD HH.mm.ss — 19 characters.
        #expect(dateComponent.count == 19)
        // Verify the date pattern: DDDD-DD-DD DD.DD.DD
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#
        #expect(dateComponent.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("camera filename format matches spec §135")
    func cameraFileName() {
        let name = RecordingOutput.fileName(timestamp: self.testDate, kind: .camera)
        #expect(name.hasPrefix("Onset "))
        #expect(name.hasSuffix("— Camera.mp4"))
        let dateComponent = name
            .dropFirst("Onset ".count)
            .dropLast(" — Camera.mp4".count)
        #expect(dateComponent.count == 19)
    }

    @Test("screen and camera share the same timestamp component")
    func screenAndCameraShareTimestamp() {
        let screen = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        let camera = RecordingOutput.fileName(timestamp: self.testDate, kind: .camera)
        let screenDate = screen.dropFirst("Onset ".count).dropLast(" — Screen.mp4".count)
        let cameraDate = camera.dropFirst("Onset ".count).dropLast(" — Camera.mp4".count)
        #expect(screenDate == cameraDate)
    }

    @Test("suffixes differ between screen and camera")
    func suffixesDiffer() {
        let screen = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        let camera = RecordingOutput.fileName(timestamp: self.testDate, kind: .camera)
        #expect(screen != camera)
    }

    /// Proves that `fileName` is sensitive to the timestamp input — i.e. a different Date
    /// produces a different date segment. This makes the `screenAndCameraShareTimestamp` test
    /// meaningful as a regression guard for #198: if the implementation ignores the timestamp
    /// argument and always uses `Date()`, this test would be flaky (fail when the clock ticks
    /// across a second boundary) and the share-timestamp test would catch nothing.
    @Test("different timestamps produce different date segments")
    func differentTimestamps_produceDifferentDateSegments() {
        // Two dates exactly one second apart — guaranteed distinct segments.
        let dateA = Date(timeIntervalSince1970: 1_749_038_205)
        let dateB = Date(timeIntervalSince1970: 1_749_038_206)

        let nameA = RecordingOutput.fileName(timestamp: dateA, kind: .screen)
        let nameB = RecordingOutput.fileName(timestamp: dateB, kind: .screen)

        let segmentA = nameA.dropFirst("Onset ".count).dropLast(" — Screen.mp4".count)
        let segmentB = nameB.dropFirst("Onset ".count).dropLast(" — Screen.mp4".count)

        #expect(
            String(segmentA) != String(segmentB),
            "one-second-apart dates must produce different date segments; got \(segmentA) == \(segmentB)"
        )
    }
}

// MARK: - RecordingOutputDirectoryTests

@Suite("RecordingOutput — directory permissions")
struct RecordingOutputDirectoryTests {
    /// Temp directory scoped to each test instance — each `@Suite` instance is fresh
    /// (Swift Testing creates a new struct value per test).
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "RecordingOutputTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    // MARK: - ensureDirectory

    @Test("ensureDirectory creates the directory")
    func ensureDirectory_creates() throws {
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        try RecordingOutput.ensureDirectory(self.tempDir)
        var isDir: ObjCBool = false
        let dirPath = self.tempDir.path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir)
        #expect(exists && isDir.boolValue)
    }

    @Test("ensureDirectory sets owner-only permissions (0o700)")
    func ensureDirectory_ownerOnlyPermissions() throws {
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        try RecordingOutput.ensureDirectory(self.tempDir)
        let attrs = try FileManager.default.attributesOfItem(atPath: self.tempDir.path(percentEncoded: false))
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test("ensureDirectory is idempotent — no error if directory already exists")
    func ensureDirectory_idempotent() throws {
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        try RecordingOutput.ensureDirectory(self.tempDir)
        // Second call must not throw.
        try RecordingOutput.ensureDirectory(self.tempDir)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: self.tempDir.path(percentEncoded: false),
            isDirectory: &isDir
        )
        #expect(exists && isDir.boolValue)
    }

    // MARK: - setOwnerOnly

    @Test("setOwnerOnly sets 0o600 on a file")
    func setOwnerOnly_setsPermissions() throws {
        // Create the parent first (setOwnerOnly operates on a file, not a directory).
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let fileURL = self.tempDir.appending(path: "test.mp4")
        // Create a file so setOwnerOnly has something to act on.
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)

        try RecordingOutput.setOwnerOnly(file: fileURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

// MARK: - RecordingOutput.uniqueOutputURL — collision guard (#198)

@Suite("RecordingOutput.uniqueOutputURL")
struct RecordingOutputUniqueURLTests {
    /// Shared fixed timestamp — same value used throughout to control the base name.
    ///
    /// 1_749_038_205 = 2026-06-04 14:30:05 UTC.
    private var testDate: Date {
        Date(timeIntervalSince1970: 1_749_038_205)
    }

    /// UUID-scoped temp directory: each `@Suite` instance is fresh so parallel tests
    /// do not share a directory.
    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appending(path: "UniqueURLTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    // MARK: - No collision

    @Test("uniqueOutputURL returns base name when no file exists")
    func noCollision_returnsBaseName() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        let name = url.lastPathComponent
        #expect(name == RecordingOutput.fileName(timestamp: self.testDate, kind: .screen))
    }

    // MARK: - Shared timestamp across kinds

    @Test("screen and camera URLs from the same timestamp share the date segment")
    func sameTimestamp_screenAndCameraShareDateSegment() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let screenURL = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        let cameraURL = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .camera)

        // Extract date segment from each name.
        let screenName = screenURL.lastPathComponent
        let cameraName = cameraURL.lastPathComponent
        let screenDate = screenName.dropFirst("Onset ".count).dropLast(" — Screen.mp4".count)
        let cameraDate = cameraName.dropFirst("Onset ".count).dropLast(" — Camera.mp4".count)

        #expect(
            String(screenDate) == String(cameraDate),
            "screen and camera must share the identical timestamp segment"
        )
    }

    // MARK: - Collision: single pre-existing file

    @Test("uniqueOutputURL appends (2) when the base name already exists")
    func collision_appendsTwoSuffix() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        // Pre-create the base file so a collision is guaranteed.
        let baseName = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        let basePath = self.tempDir.appending(path: baseName).path(percentEncoded: false)
        FileManager.default.createFile(atPath: basePath, contents: nil)

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        let name = url.lastPathComponent
        #expect(name.hasSuffix("(2).mp4"), "expected (2) disambiguator, got: \(name)")
        #expect(name.hasPrefix("Onset "), "must keep the Onset prefix: \(name)")
        #expect(name != baseName, "must be different from the colliding base name")
    }

    // MARK: - Collision: multiple pre-existing files

    @Test("uniqueOutputURL increments counter past existing (2) file")
    func collision_incrementsCounterPastTwo() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let base = RecordingOutput.fileName(timestamp: self.testDate, kind: .camera)
        let stem = URL(filePath: base).deletingPathExtension().lastPathComponent
        // Pre-create base + (2) to force counter to reach (3).
        let basePath = self.tempDir.appending(path: base).path(percentEncoded: false)
        let twoPath = self.tempDir.appending(path: "\(stem) (2).mp4").path(percentEncoded: false)
        FileManager.default.createFile(atPath: basePath, contents: nil)
        FileManager.default.createFile(atPath: twoPath, contents: nil)

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .camera)
        let name = url.lastPathComponent
        #expect(name.hasSuffix("(3).mp4"), "expected (3) disambiguator, got: \(name)")
    }

    // MARK: - Kind mapping correctness

    @Test("uniqueOutputURL — screen kind produces a — Screen suffix")
    func kindMapping_screen() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        #expect(url.lastPathComponent.contains("— Screen"), "screen kind must embed — Screen suffix")
    }

    @Test("uniqueOutputURL — camera kind produces a — Camera suffix")
    func kindMapping_camera() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .camera)
        #expect(url.lastPathComponent.contains("— Camera"), "camera kind must embed — Camera suffix")
    }

    // MARK: - Uniquifier result does not exist on disk

    @Test("uniqueOutputURL result path does not exist on disk after collision")
    func collision_resultDoesNotExistOnDisk() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        // Pre-create the base to force a collision.
        let baseName = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        FileManager.default.createFile(
            atPath: self.tempDir.appending(path: baseName).path(percentEncoded: false),
            contents: nil
        )

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        #expect(
            !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            "the returned URL must not already exist on disk"
        )
    }

    // MARK: - Counter exhaustion fallback

    /// When the base file plus every suffixed candidate `(2)`…`(999)` already exist,
    /// `uniqueOutputURL` returns the unsuffixed base name and lets `AVAssetWriter` surface
    /// the error — the documented fallback (spec §uniqueOutputURL, implementation comment).
    @Test("uniqueOutputURL returns base name when all counters 2…999 are exhausted")
    func counterExhaustion_returnsBaseName() throws {
        try FileManager.default.createDirectory(at: self.tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: self.tempDir) }

        let baseName = RecordingOutput.fileName(timestamp: self.testDate, kind: .screen)
        let stem = URL(filePath: baseName).deletingPathExtension().lastPathComponent

        // Pre-create the base file.
        FileManager.default.createFile(
            atPath: self.tempDir.appending(path: baseName).path(percentEncoded: false),
            contents: nil
        )

        // Pre-create (2)…(999) — 998 additional files — to exhaust every disambiguator slot.
        for counter in 2...999 {
            let candidate = "\(stem) (\(counter)).mp4"
            FileManager.default.createFile(
                atPath: self.tempDir.appending(path: candidate).path(percentEncoded: false),
                contents: nil
            )
        }

        let url = RecordingOutput.uniqueOutputURL(in: self.tempDir, timestamp: self.testDate, kind: .screen)
        #expect(
            url.lastPathComponent == baseName,
            "exhausted counters must fall back to the base name, got: \(url.lastPathComponent)"
        )
    }
}
