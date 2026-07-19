import Foundation
@testable import Onset
import Testing

// MARK: - LiveDiskSpaceProviderTests

/// L2 coverage for T-2 acceptance: nil-on-failure, same-volume dedup, nearest-existing-ancestor
/// resolution, and the fixed system-volume path.
@Suite("LiveDiskSpaceProvider")
struct LiveDiskSpaceProviderTests {
    private let sut = LiveDiskSpaceProvider()

    /// Given a URL that cannot resolve to a file-system volume (a non-`file://` scheme), When
    /// `snapshot` is called, Then `outputFreeBytes` is `nil` — never a fabricated number.
    @Test
    func snapshot_nonFileOutputURL_yieldsNilOutputFreeBytes() async throws {
        let unresolvableURL = try #require(URL(string: "https://example.invalid/output.mp4"))

        let snapshot = await self.sut.snapshot(outputURL: unresolvableURL)

        #expect(snapshot.outputFreeBytes == nil)
    }

    /// Given output and system paths that resolve to the SAME volume (the common case on a
    /// single-disk dev machine: the temp directory and `/System/Volumes/Data` are both on the
    /// Data volume), When snapshotted, Then `sameVolume == true` and both free-byte values are
    /// equal (the dedup path reuses one read for both fields — see file-level note below on why a
    /// stronger read-count assertion wasn't added from this black-box test).
    @Test
    func snapshot_outputOnSameVolumeAsSystem_reportsSameVolumeAndEqualFreeBytes() async throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("onset-t2-output.mp4")

        let snapshot = await self.sut.snapshot(outputURL: outputURL)

        #expect(snapshot.sameVolume)
        let outputFreeBytes = try #require(snapshot.outputFreeBytes)
        let systemFreeBytes = try #require(snapshot.systemFreeBytes)
        #expect(outputFreeBytes == systemFreeBytes)
    }

    /// Given an `outputURL` whose immediate parent directory does not exist (the session-scoped
    /// output directory has not been created yet), When `snapshot` is called, Then
    /// `outputFreeBytes` is still resolved (non-`nil`) from the nearest EXISTING ancestor — here,
    /// the real temp directory two levels up — not `nil`.
    @Test
    func snapshot_missingImmediateParent_resolvesFromNearestExistingAncestor() async {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onset-t2-does-not-exist-\(UUID().uuidString)")
            .appendingPathComponent("deeper")
        let outputURL = missingDirectory.appendingPathComponent("output.mp4")

        // Confirm the fixture actually exercises the "missing ancestor" path.
        #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))

        let snapshot = await self.sut.snapshot(outputURL: outputURL)

        #expect(snapshot.outputFreeBytes != nil)
    }

    /// Given a normal dev machine, When `snapshot` is called, Then `systemFreeBytes` resolves
    /// (non-`nil`) from the fixed `/System/Volumes/Data` path.
    @Test
    func snapshot_systemVolume_resolvesNonNilFreeBytes() async {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("onset-t2-system.mp4")

        let snapshot = await self.sut.snapshot(outputURL: outputURL)

        #expect(snapshot.systemFreeBytes != nil)
    }
}

// Note on the "exactly ONE expensive read" acceptance bullet (T-2 tasks.md): asserting the precise
// number of `.volumeAvailableCapacityForImportantUsageKey` reads from a black-box test would
// require an invasive internal hook (the actor's queue/signposter are private, by design, so the
// non-`Sendable` `volumeIdentifier` never leaves the actor). Instead,
// `snapshot_outputOnSameVolumeAsSystem_reportsSameVolumeAndEqualFreeBytes` asserts the observable
// consequence of the dedup path: `outputFreeBytes == systemFreeBytes` (both populated from the one
// shared read) and `sameVolume == true`. The implementation's dedup branch (`LiveDiskSpaceProvider
// .snapshot`) is structurally single-read on the `sameVolume` branch — reviewed at the source level
// in the task report.
