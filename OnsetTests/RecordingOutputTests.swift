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
