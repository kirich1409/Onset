import Foundation
@testable import Onset

// MARK: - Fake

/// In-memory fake `DiskSpaceProviding` for unit tests.
///
/// All state is per-instance — safe under Swift Testing's parallel-by-default execution
/// (each `@Test` in a `@Suite struct` receives a fresh instance).
///
/// `DiskSpaceProviding` is a `nonisolated protocol` whose `snapshot(outputURL:)` requirement is
/// `nonisolated async` — a `@MainActor` class can't satisfy that while also mutating its own
/// main-actor state from within the (necessarily nonisolated) witness. An `actor` satisfies the
/// requirement naturally: `snapshot(outputURL:)` is actor-isolated async, and callers on any actor
/// (including `@MainActor` tests) reach the scriptable state and call log via `await`.
actor FakeDiskSpaceProvider: DiskSpaceProviding {
    // MARK: - Scriptable snapshot

    /// Free bytes on the output volume the next `snapshot(outputURL:)` call returns.
    var outputFreeBytes: Int64?

    /// Free bytes on the system volume the next `snapshot(outputURL:)` call returns.
    var systemFreeBytes: Int64?

    /// Whether the next `snapshot(outputURL:)` call reports the output and system volumes as the
    /// same volume.
    var sameVolume = false

    /// Artificial delay before `snapshot(outputURL:)` resolves — lets tests simulate a slow
    /// provider (overlapping-refresh scenarios in T-4/T-6).
    var delayNanoseconds: UInt64 = 0

    // MARK: - Call tracking

    /// Every `outputURL` passed to `snapshot(outputURL:)`, in call order.
    private(set) var calls: [URL] = []

    /// Number of times `snapshot(outputURL:)` was called.
    var callCount: Int {
        self.calls.count
    }

    // MARK: - Scripting helpers

    /// Configures the scriptable snapshot fields in one `await` — actor-isolated `var`
    /// properties can only be mutated from inside the actor (an external `await actor.prop =
    /// value` does not compile), so callers reach for this instead of individual setters.
    func configure(
        outputFreeBytes: Int64?,
        systemFreeBytes: Int64?,
        sameVolume: Bool = false,
        delayNanoseconds: UInt64 = 0
    ) {
        self.outputFreeBytes = outputFreeBytes
        self.systemFreeBytes = systemFreeBytes
        self.sameVolume = sameVolume
        self.delayNanoseconds = delayNanoseconds
    }

    /// Updates just the next snapshot's output free-bytes reading, leaving every other
    /// scripted field as-is.
    func setOutputFreeBytes(_ freeBytes: Int64?) {
        self.outputFreeBytes = freeBytes
    }

    // MARK: - DiskSpaceProviding

    func snapshot(outputURL: URL) async -> DiskVolumesSnapshot {
        self.calls.append(outputURL)
        if self.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: self.delayNanoseconds)
        }
        return DiskVolumesSnapshot(
            outputFreeBytes: self.outputFreeBytes,
            systemFreeBytes: self.systemFreeBytes,
            sameVolume: self.sameVolume
        )
    }
}
