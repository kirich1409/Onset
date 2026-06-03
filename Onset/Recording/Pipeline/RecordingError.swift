import Foundation

/// Errors emitted by the recording pipeline.
///
/// Each case is tied to the acceptance criterion or spec section that motivates it.
/// Cases are documented inline.
///
/// All members are `nonisolated` so this error type is usable from any isolation context
/// (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated enum RecordingError: Error {
    // MARK: - Pre-flight / CapabilityProbe errors

    /// No hardware HEVC encoder is available on this machine. AC-6.
    ///
    /// Emitted when `VTCompressionSession` with `RequireHardwareAcceleratedVideoEncoder = true`
    /// fails or reports `Using == false`. Recording must NOT silently fall back to software
    /// encoding — this error is surfaced to the user immediately.
    case noHardwareEncoder

    /// The combined pixel-rate of the selected sources exceeds the engine throughput cap.
    ///
    /// Emitted by CapabilityProbe pre-flight when the sum of
    /// `screen_w × screen_h × screen_fps + camera_w × camera_h × camera_fps` exceeds
    /// `RecordingConfiguration.budgetCap.maxPixelsPerSecond` after applying the
    /// downscale/fps-reduction heuristic (AC-5). If the cap cannot be satisfied even at
    /// the minimum downscale, the session must not start.
    case budgetExceeded

    // MARK: - Source errors

    /// No video source is available to record.
    ///
    /// Recording requires at least one video source (screen or camera). Emitted when
    /// effective permissions allow neither (AC-2, AC-3).
    case noVideoSource

    // MARK: - Discovery errors

    /// `SCShareableContent.current` failed during display enumeration.
    ///
    /// Wraps the underlying error thrown by `SCShareableContent.current`. Emitted when
    /// screen-recording permission is granted but ScreenCaptureKit still refuses to
    /// enumerate displays (e.g. sandboxing, hardware failure, first-launch TCC race).
    case displayDiscoveryFailed(any Error)

    // MARK: - Setup errors

    /// ScreenCaptureKit / SCStream setup failed.
    ///
    /// Wraps the underlying error for diagnostics. Emitted during stream configuration
    /// before the first frame is captured.
    case captureSetupFailed(any Error)

    /// `VTCompressionSession` configuration failed.
    ///
    /// Wraps the underlying `OSStatus` or error. Emitted when any mandatory encoder
    /// property (profile level, colour info, rate control) cannot be set.
    case encoderSetupFailed(any Error)

    /// `AVAssetWriter` or `AVAssetWriterInput` setup failed.
    ///
    /// Wraps the underlying error. Emitted when the writer cannot be initialised for
    /// the output URL (e.g. file already exists, output directory not found/accessible).
    case writerSetupFailed(any Error)

    // MARK: - Runtime errors

    /// The output directory (`~/Movies/Onset/`) could not be created or accessed.
    ///
    /// Emitted when `FileManager.createDirectory` fails at session start. The wrapped
    /// error provides the system reason (permissions, read-only volume, etc.).
    case outputDirectoryUnavailable(any Error)

    /// The asset writer transitioned to `.failed` status during an active session.
    ///
    /// Wraps `AVAssetWriter.error`. Partial output may exist on disk; the caller should
    /// surface the path so the user can recover any usable footage (AC-10 crash recovery
    /// intent: `movieFragmentInterval` limits data loss, but the writer may still fail).
    case writerFailed(any Error)
}

extension RecordingError: Equatable {
    /// Manual `nonisolated` implementation.
    ///
    /// Associated-value `Error` cases compare by their `localizedDescription` as a best
    /// effort — two distinct errors with the same message compare equal, which is
    /// acceptable for unit-test assertions on error type.
    nonisolated static func == (lhs: RecordingError, rhs: RecordingError) -> Bool {
        switch (lhs, rhs) {
        case (.noHardwareEncoder, .noHardwareEncoder),
             (.budgetExceeded, .budgetExceeded),
             (.noVideoSource, .noVideoSource):
            true

        case let (.captureSetupFailed(lErr), .captureSetupFailed(rErr)),
             let (.encoderSetupFailed(lErr), .encoderSetupFailed(rErr)),
             let (.writerSetupFailed(lErr), .writerSetupFailed(rErr)),
             let (.outputDirectoryUnavailable(lErr), .outputDirectoryUnavailable(rErr)),
             let (.writerFailed(lErr), .writerFailed(rErr)),
             let (.displayDiscoveryFailed(lErr), .displayDiscoveryFailed(rErr)):
            lErr.localizedDescription == rErr.localizedDescription

        default:
            false
        }
    }
}
