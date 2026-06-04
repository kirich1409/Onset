import AVFoundation
import CoreMedia

// MARK: - WriterInputSeam

/// Injectable seam over `AVAssetWriterInput` readiness and sample appending.
///
/// Abstracts the two operations `FileWriter` calls per frame so that L2 tests can
/// inject a stub that simulates `isReadyForMoreMediaData == false` — a state that
/// cannot be forced on a real `AVAssetWriterInput` outside a live session.
///
/// `nonisolated` so the actor can call the seam without a hop:
/// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a protocol without an explicit
/// isolation annotation is inferred `@MainActor`, which would require the actor to
/// async-hop on every call. Pattern mirrors `CompressionSession` in VideoEncoderTypes.swift.
///
/// Not `Sendable` — the live implementation wraps `AVAssetWriterInput` which is not
/// Sendable. The seam is held by the `FileWriter` actor and never shared across
/// isolation boundaries.
nonisolated protocol WriterInputSeam {
    /// Whether the underlying input is ready to accept more data.
    nonisolated var isReadyForMoreMediaData: Bool { get }

    /// Appends a sample buffer. Returns `true` on success.
    @discardableResult
    nonisolated func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

// MARK: - Live wrapper

/// Live `WriterInputSeam` backed by a real `AVAssetWriterInput`.
///
/// `@unchecked Sendable`: `AVAssetWriterInput` is not `Sendable`, but this wrapper is
/// created and used only from within the `FileWriter` actor; it never crosses an isolation
/// boundary. The actor is the synchronisation.
///
/// `nonisolated` cannot be applied to `input` because `AVAssetWriterInput` is not
/// `Sendable` — the type checker rejects `nonisolated let` for non-Sendable stored
/// properties. Access to `input` from the actor context is safe because the actor
/// provides the synchronisation.
nonisolated final class LiveWriterInput: WriterInputSeam, @unchecked Sendable {
    /// The underlying input. Also accessible for `markAsFinished()` and `add()`.
    let input: AVAssetWriterInput

    nonisolated init(_ input: AVAssetWriterInput) {
        self.input = input
    }

    nonisolated var isReadyForMoreMediaData: Bool {
        self.input.isReadyForMoreMediaData
    }

    @discardableResult
    nonisolated func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.input.append(sampleBuffer)
    }
}

// MARK: - FinishResult

/// The outcome of `FileWriter.finish()`.
///
/// Each case carries the output `url` — the path is reserved regardless of the outcome,
/// so callers can inspect, move, or delete the file in every branch.
///
/// The three cases map directly to `AVAssetWriter.Status` after `finishWriting()` returns:
/// - `.completed` → status `.completed` (normal termination).
/// - `.cancelled`  → status `.cancelled` (caller cancelled before all data was written).
/// - `.failed`     → status `.failed` (hard writer error); `error` is the writer's error when
///   available, or a `FileWriterError.finishFailed(nil)` sentinel for `.unknown`/`.writing`
///   residual states (should not occur in practice but mapped for exhaustiveness).
///
/// `AVAssetWriter.Status` is NOT part of the public surface — the cases here are the contract.
nonisolated enum FinishResult {
    /// The file was written successfully.
    case completed(url: URL)
    /// The write was cancelled before completion.
    case cancelled(url: URL)
    /// The write failed with an error.
    case failed(url: URL, error: any Error)
}

// MARK: - AudioSettingsSnapshot

/// Typed snapshot of AAC audio settings — all fields `Sendable` so they can cross
/// the actor boundary from `FileWriter.audioSettingsForTesting`.
///
/// Declared `nonisolated struct` with `nonisolated let` members: under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a plain `struct` has its stored
/// properties inferred `@MainActor`, making them inaccessible from `nonisolated`
/// test contexts and `#require` macro expansions.
nonisolated struct AudioSettingsSnapshot {
    nonisolated let formatID: UInt32?
    nonisolated let sampleRate: Double?
    nonisolated let channelCount: Int?
    nonisolated let bitrate: Int?
}

// MARK: - FileWriterError

/// Errors thrown by or synthesized within `FileWriter`.
nonisolated enum FileWriterError: Error {
    /// `AVAssetWriter.startWriting()` returned `false`.
    case startFailed((any Error)?)
    /// `AVAssetWriter.finishWriting()` ended in an unexpected terminal state (`.unknown` or
    /// `.writing`). Carries the writer's error when available. Synthesized as the `error`
    /// payload of `FinishResult.failed` when the writer's own `error` is `nil` in those states.
    case finishFailed((any Error)?)
}

extension FileWriterError: Equatable {
    nonisolated static func == (lhs: FileWriterError, rhs: FileWriterError) -> Bool {
        switch (lhs, rhs) {
        case (.startFailed, .startFailed):
            true

        case (.finishFailed, .finishFailed):
            true

        default:
            false
        }
    }
}
