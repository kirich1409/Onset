import Foundation
import os

// MARK: - Logger

nonisolated private let diskSpaceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DiskSpace"
)

// MARK: - DiskVolumesSnapshot

/// A `Sendable` snapshot of free-space information for the output volume and the system volume.
///
/// The raw `URLResourceValues.volumeIdentifier` (Apple type `(NSCopying & NSObjectProtocol)?`) is
/// NOT `Sendable` and must never cross the actor boundary — `LiveDiskSpaceProvider` resolves both
/// volume identifiers and computes `sameVolume` entirely inside the actor, returning only this
/// value type.
nonisolated struct DiskVolumesSnapshot: Sendable {
    /// Bytes available on the output volume for important-usage writes, or `nil` if the read
    /// failed. Never a fabricated/stale number — a failed read is `nil`, not `0`.
    let outputFreeBytes: Int64?

    /// Bytes available on the system volume (`/System/Volumes/Data`) for important-usage writes,
    /// or `nil` if the read failed.
    let systemFreeBytes: Int64?

    /// `true` when the output volume and the system volume are the same volume, determined by
    /// comparing `volumeIdentifier` (not path strings) inside the actor.
    let sameVolume: Bool
}

// MARK: - DiskSpaceProviding

/// The seam `DiskSpaceMonitor` (T-4) uses to read free disk space for the output volume and the
/// system volume.
///
/// `nonisolated protocol` so the live `actor` conformer satisfies the `async` requirement without
/// the protocol itself being inferred `@MainActor` (mirrors `EncoderControlling` / `WriterControlling`
/// in `RecordingComponentFactories.swift`).
nonisolated protocol DiskSpaceProviding: Sendable {
    /// Reads free-space information for the volume containing `outputURL` and for the system
    /// volume, resolving them off the calling actor.
    ///
    /// - Parameter outputURL: The recording's destination file URL. Its containing directory may
    ///   not exist yet (the session-scoped output directory is created lazily), so the resolution
    ///   walks up to the nearest existing ancestor.
    func snapshot(outputURL: URL) async -> DiskVolumesSnapshot
}

// MARK: - LiveDiskSpaceProvider

/// Live `DiskSpaceProviding`: reads `URLResourceValues` off a dedicated serial queue.
///
/// ### Why a dedicated `DispatchQueue`, not the cooperative pool
/// `URL.resourceValues(forKeys:)` is a blocking, potentially slow (XPC-backed) synchronous call.
/// Running it directly inside an `async` actor method would block a cooperative-thread-pool
/// thread for the duration of the read. This actor instead owns a private serial `DispatchQueue`
/// and bridges the blocking call off it via `withCheckedContinuation` — only the blocking call
/// itself is relocated; there is no custom actor-wide `SerialExecutor` / `unownedExecutor`
/// override (that would be a much larger hammer for a single blocking call).
///
/// ### Perf: cheap `volumeIdentifierKey` compare before the expensive read
/// `.volumeIdentifierKey` is read for BOTH paths first. When they match (single-volume setup, the
/// common case), exactly ONE `.volumeAvailableCapacityForImportantUsageKey` read is issued and its
/// value is reused for both `outputFreeBytes` and `systemFreeBytes`. When they differ, two
/// separate expensive reads are issued.
actor LiveDiskSpaceProvider: DiskSpaceProviding {
    /// Fixed path Apple documents as the writable system data volume mount point.
    private static let systemVolumePath = "/System/Volumes/Data"

    /// Dedicated serial queue the blocking `resourceValues(forKeys:)` calls run on — never the
    /// cooperative thread pool, never the main thread.
    private let ioQueue = DispatchQueue(label: "dev.androidbroadcast.Onset.DiskSpaceProvider")

    /// Signpost log for measuring blocking-read latency (shares the file-scope `diskSpaceLogger`'s
    /// subsystem/category so signposts are filterable alongside regular log lines).
    private let signposter = OSSignposter(logger: diskSpaceLogger)

    /// Creates a live provider. Stateless beyond the dedicated queue/signposter — safe to share
    /// as a single instance across the app (T-11 composition root).
    init() {}

    func snapshot(outputURL: URL) async -> DiskVolumesSnapshot {
        let systemURL = URL(fileURLWithPath: Self.systemVolumePath)

        // A non-file-URL `outputURL` (e.g. a `https://` scheme) has no volume to resolve at all —
        // `resourceValues(forKeys:)` only supports file URLs, and there is no meaningful ancestor
        // directory to walk up to. Fail closed to `nil` here rather than feeding a nonsensical
        // path into the ancestor walk (which could otherwise loop without making progress on a
        // path that never reaches a real filesystem root).
        guard outputURL.isFileURL else {
            let systemFreeBytes = await self.importantUsageFreeBytes(at: systemURL)
            return DiskVolumesSnapshot(outputFreeBytes: nil, systemFreeBytes: systemFreeBytes, sameVolume: false)
        }

        let outputAncestor = await self.nearestExistingAncestor(of: outputURL)
        let sameVolume = await self.resolveSameVolume(outputPath: outputAncestor, systemPath: systemURL)

        if sameVolume {
            let sharedFreeBytes = await self.importantUsageFreeBytes(at: outputAncestor)
            return DiskVolumesSnapshot(
                outputFreeBytes: sharedFreeBytes,
                systemFreeBytes: sharedFreeBytes,
                sameVolume: true
            )
        }

        let outputFreeBytes = await self.importantUsageFreeBytes(at: outputAncestor)
        let systemFreeBytes = await self.importantUsageFreeBytes(at: systemURL)
        return DiskVolumesSnapshot(
            outputFreeBytes: outputFreeBytes,
            systemFreeBytes: systemFreeBytes,
            sameVolume: false
        )
    }

    /// Reads `.volumeIdentifierKey` for BOTH paths on the dedicated queue and compares them with
    /// `isEqual` — entirely inside the closure, so the non-`Sendable` `(NSCopying &
    /// NSObjectProtocol)?` value never crosses back through the continuation; only the resulting
    /// `Bool` does. Two failed reads (both `nil`) are treated as NOT the same volume — never
    /// fabricate agreement out of two failures.
    private func resolveSameVolume(outputPath: URL, systemPath: URL) async -> Bool {
        let queue = self.ioQueue
        let interval = self.signposter.beginInterval("volumeIdentifierRead")
        defer { self.signposter.endInterval("volumeIdentifierRead", interval) }
        return await withCheckedContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .onQueue(queue))
                let outputValues = try? outputPath.resourceValues(forKeys: [.volumeIdentifierKey])
                let systemValues = try? systemPath.resourceValues(forKeys: [.volumeIdentifierKey])
                guard let outputIdentifier = outputValues?.volumeIdentifier,
                      let systemIdentifier = systemValues?.volumeIdentifier
                else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: outputIdentifier.isEqual(systemIdentifier))
            }
        }
    }

    /// Walks `deletingLastPathComponent()` upward from `url` until an existing ancestor directory
    /// (or `/`) is found. `resourceValues(forKeys:)` on a nonexistent path throws/returns garbage,
    /// and the output's base directory may not exist yet at snapshot time.
    ///
    /// `queue` is captured as a local constant (not read as `self.ioQueue` inside the closure) so
    /// the `@Sendable` closure handed to `DispatchQueue.async` does not need to hop back through
    /// actor isolation to read a stored property — it is a plain `Sendable` value from here on.
    private func nearestExistingAncestor(of url: URL) async -> URL {
        let queue = self.ioQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .onQueue(queue))
                var candidate = url
                let root = URL(fileURLWithPath: "/")
                while candidate.path != root.path {
                    let parent = candidate.deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: parent.path) {
                        continuation.resume(returning: parent)
                        return
                    }
                    candidate = parent
                }
                continuation.resume(returning: root)
            }
        }
    }

    /// Reads `.volumeAvailableCapacityForImportantUsageKey` at `url` off the dedicated queue.
    /// `nil` on any read failure or nil key — never a fabricated/stale byte count.
    private func importantUsageFreeBytes(at url: URL) async -> Int64? {
        let queue = self.ioQueue
        let interval = self.signposter.beginInterval("importantUsageRead")
        defer { self.signposter.endInterval("importantUsageRead", interval) }
        return await withCheckedContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .onQueue(queue))
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                continuation.resume(returning: values?.volumeAvailableCapacityForImportantUsage)
            }
        }
    }
}
