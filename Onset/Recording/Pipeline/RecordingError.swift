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

    // MARK: - Camera format errors

    /// No camera format satisfies the minimum fps requirement (AC-5: fps ≥ 30).
    ///
    /// Emitted by `CameraFormatSelector.pickBestFormat(from:minFps:)` when every
    /// advertised format for the selected camera has `maxFps < minFps`. Recording
    /// must NOT silently start at a lower frame rate — this violates the ≥30fps
    /// invariant that downstream encoders and the ResolvedRecordingPlan depend on.
    ///
    /// Callers should surface a "Camera does not support 30fps" message and exclude
    /// the device, rather than downgrading the frame rate target.
    case noSuitableCameraFormat

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

    /// Screen capture did not activate within the allowed window.
    ///
    /// On macOS 26 `SCStream.startCapture()` returns before the user responds to the
    /// screen-recording consent dialog. The coordinator waits for the first real screen
    /// frame as the activation signal. This error is thrown when:
    ///
    /// - the consent dialog is dismissed / denied (the stream emits a terminal stop
    ///   event and `captureActiveStream` finishes without yielding),
    /// - macOS silently denies consent without emitting a terminal stop and the
    ///   bounded timeout (~30 s) elapses, or
    /// - any other terminal stop occurs before the first frame.
    ///
    /// Recording is automatically reverted to the pre-recording state before this error
    /// propagates to the UI.
    case captureDidNotActivate
}

extension RecordingError: LocalizedError {
    /// Actionable description surfaced to the user.
    ///
    /// Only `captureDidNotActivate` returns a string; other cases fall through to Swift's
    /// default formatting — their callers set explicit UI copy at the call site.
    nonisolated var errorDescription: String? {
        switch self {
        case .captureDidNotActivate:
            // Actionable instruction: tell the user where to grant permission and how to retry.
            "Не удалось начать запись экрана. " +
                "Разрешите запись экрана в Системных настройках → " +
                "Конфиденциальность и безопасность → Запись экрана и попробуйте снова."

        default:
            nil
        }
    }
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
             (.noVideoSource, .noVideoSource),
             (.noSuitableCameraFormat, .noSuitableCameraFormat),
             (.captureDidNotActivate, .captureDidNotActivate):
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
