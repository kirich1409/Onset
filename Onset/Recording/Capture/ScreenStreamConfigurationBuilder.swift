import CoreMedia
import CoreVideo
import ScreenCaptureKit

// MARK: - ScreenStreamConfigurationBuilder

/// Builds an `SCStreamConfiguration` from a resolved recording plan and policy.
///
/// This is a pure mapping layer — no live capture, no display access, no permissions needed.
/// All invariants (even dims, fps cap, budget fit) are pre-validated by `CapabilityResolver`;
/// this builder consumes the already-resolved values directly.
///
/// ### Thread safety
/// The entry point is `nonisolated static func` and creates a new `SCStreamConfiguration`
/// each call. Safe to invoke from any actor context.
nonisolated enum ScreenStreamConfigurationBuilder {
    // MARK: - Constants

    /// Capture queue depth for `SCStreamConfiguration.queueDepth`.
    ///
    /// The ScreenCaptureKit header (`SCStream.h`) states:
    /// "Determines the number of frames kept in the queue. The default value is 8 and
    /// should not exceed 8." Both the default and the ceiling are 8.
    private static let captureQueueDepth = 8

    // MARK: - Public API

    /// Returns a fully-configured `SCStreamConfiguration` for the given recording plan.
    ///
    /// - Parameters:
    ///   - plan: Resolved start profile produced by `CapabilityResolver`. All screen
    ///     dimensions and fps are pre-validated; this function does not re-derive them.
    ///   - config: Recording policy. Only `pixelFormatPreference` is consumed here; all
    ///     other fields (codec, bitrate, color metadata) belong to downstream layers.
    /// - Returns: A new `SCStreamConfiguration` ready to pass to `SCStream.init`.
    nonisolated static func makeConfiguration(
        plan: ResolvedRecordingPlan,
        config: RecordingConfiguration
    )
    -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()

        // Frame dimensions — already capped, downscaled, and forced-even by CapabilityResolver.
        // Do NOT re-derive or re-clamp here; consume the plan's values as the single source of truth.
        streamConfig.width = plan.screenWidth
        streamConfig.height = plan.screenHeight

        // Rate cap: deliver at most `screenFps` frames per second.
        // CMTime(value:timescale:) with value=1 and timescale=fps encodes "1/fps seconds per frame".
        streamConfig.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(plan.screenFps)
        )

        // Pixel format: use the most-preferred format the policy lists, falling back to
        // the video-range biplanar format. `first` returns Optional — `?? .biPlanar420v`
        // avoids force-unwrapping (force_unwrapping lint rule is enabled in this project).
        let preferredFormat = config.pixelFormatPreference.first ?? .biPlanar420v
        streamConfig.pixelFormat = Self.osType(for: preferredFormat)

        // Queue depth: header confirms 8 is both the default and the maximum.
        streamConfig.queueDepth = Self.captureQueueDepth

        // Color space: Rec.709 SDR.
        // CGColorSpace.itur_709 is a CFString constant exposed via CoreGraphics.apinotes.
        // `unsafe` is required: `colorSpaceName` is typed `CFStringRef` (unmanaged C pointer),
        // which the compiler flags as unsafe under STRICT_MEMORY_SAFETY=YES.
        // The value is a process-lifetime constant — memory management is safe.
        unsafe streamConfig.colorSpaceName = CGColorSpace.itur_709 as CFString

        // YCbCr matrix: Rec.709.
        // kCVImageBufferYCbCrMatrix_ITU_R_709_2 (CoreVideo) is the non-deprecated alternative
        // to the deprecated CGDisplayStream.yCbCrMatrix_ITU_R_709_2.
        // Both resolve to the same underlying string "ITU_R_709_2".
        // `unsafe` is required: `colorMatrix` is typed `CFStringRef` — same rationale as above.
        unsafe streamConfig.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2

        // Audio is captured via AVCapture (mic only per MVP spec), not via SCStream system audio.
        streamConfig.capturesAudio = false

        // Show the cursor — explicit per spec ("showsCursor = true").
        // The SCStream.h header notes cursor is visible by default; this is explicit intent.
        streamConfig.showsCursor = true

        return streamConfig
    }

    // MARK: - Private helpers

    /// Maps a `PixelFormat` policy value to the corresponding `OSType` constant.
    nonisolated private static func osType(for format: PixelFormat) -> OSType {
        switch format {
        case .biPlanar420v:
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange — "420v" (video-range)
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        case .biPlanar420f:
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange — "420f" (full-range)
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }
}
