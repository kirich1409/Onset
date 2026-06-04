// VideoEncoderTypes.swift
// Onset
//
// U3 of #31 — shared contract types for the VideoEncoder actor: the C-callback → AsyncStream
// bridge (`EncodedSampleSink`), the injectable session seam (`CompressionSession`), and the
// internal hard-fail error (`VideoEncoderError`).
//
// Split out of VideoEncoder.swift to keep that file within the project's length limit. These
// are the encoder's boundary contract; the actor (VideoEncoder.swift) consumes them and the
// production wrapper (VideoEncoder+LiveSession.swift) implements `CompressionSession`.
//
// Memory safety: VideoToolbox / CoreMedia C-interop is wrapped in `unsafe` under
// `SWIFT_STRICT_MEMORY_SAFETY = YES`, mirroring CapabilityProbe.swift.

import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - EncodedSampleSink

/// The C-callback → AsyncStream bridge target.
///
/// The `VTCompressionOutputCallback` is a C function pointer that fires on VideoToolbox's
/// internal encode queue. It receives an opaque `refcon`; this sink is what the refcon points
/// at. The sink holds ONLY the stream continuation — never the actor and never the
/// `VTCompressionSessionRef` — so it is trivially safe to touch from VT's thread:
/// `AsyncStream.Continuation.yield` is documented thread-safe from any context.
///
/// `@unchecked Sendable` rationale: the single stored property is an immutable `let`
/// continuation whose `yield` is itself thread-safe. Nothing mutable is shared.
final class EncodedSampleSink: @unchecked Sendable {
    private let continuation: AsyncStream<EncodedSample>.Continuation

    nonisolated init(continuation: AsyncStream<EncodedSample>.Continuation) {
        self.continuation = continuation
    }

    /// Builds an `EncodedSample` from a compressed `CMSampleBuffer` and yields it.
    ///
    /// Called from the C output callback. The PTS is read back from the produced buffer
    /// (`CMSampleBufferGetPresentationTimeStamp`) so `EncodedSample.ptsHostTime` is exactly
    /// the anchored PTS the actor passed into `encodeFrame` — VT preserves it. This keeps the
    /// sink anchor-free.
    nonisolated func yield(sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        let sample = EncodedSample(sampleBuffer: sampleBuffer, ptsHostTime: pts, isKeyframe: isKeyframe)
        self.continuation.yield(sample)
    }

    /// Determines whether an encoded sample is a sync (key) frame.
    ///
    /// Per the CoreMedia header: `kCMSampleAttachmentKey_NotSync` absent (or `false`) implies
    /// a sync sample. So a frame is a keyframe unless `NotSync == true`.
    nonisolated static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0
        else {
            // No attachments → treat as sync (matches "absence implies Sync").
            return true
        }
        // `unsafe`: CFArrayGetValueAtIndex returns a raw UnsafeRawPointer under
        // SWIFT_STRICT_MEMORY_SAFETY = YES. The dictionary is owned by the array; we only read.
        let raw = unsafe CFArrayGetValueAtIndex(attachments, 0)
        guard let raw = unsafe raw else { return true }
        let dict = unsafe unsafeBitCast(raw, to: CFDictionary.self)
        let notSyncKey = unsafe Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        // `unsafe`: CFDictionaryGetValue takes raw key/value pointers.
        guard let valueRaw = unsafe CFDictionaryGetValue(dict, notSyncKey) else {
            // NotSync key absent → sync sample → keyframe.
            return true
        }
        let value = unsafe unsafeBitCast(valueRaw, to: CFBoolean.self)
        // NotSync == true → delta frame (not key); NotSync == false → key.
        return !CFBooleanGetValue(value)
    }
}

// MARK: - CompressionSession seam

/// The injectable compression-session seam.
///
/// Abstracts the exact `VTCompressionSession` operations the actor needs so L2 tests can
/// substitute a mock (no hardware): force the DataRateLimits `kVTPropertyNotSupportedErr`
/// fallback, force the not-ready backpressure path, and record the PTS / pixel buffer handed
/// to `encodeFrame` for the anchored-PTS and hold assertions.
///
/// All methods are `nonisolated` because the actor calls them while isolated; the protocol
/// itself is `nonisolated` (under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` it would
/// otherwise be inferred `@MainActor` and unusable from the actor) but NOT `Sendable` — the
/// concrete `LiveCompressionSession` wraps the `CM_SWIFT_NONSENDABLE` session and is held
/// only by the actor, never shared.
nonisolated protocol CompressionSession {
    /// Sets a session property. Returns the raw `OSStatus` so the caller can branch on
    /// `kVTPropertyNotSupportedErr` for the DataRateLimits fallback.
    nonisolated func setProperty(key: CFString, value: CFTypeRef) -> OSStatus

    /// Presents a frame for compression. The output arrives asynchronously on the sink.
    nonisolated func encodeFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> OSStatus

    /// Number of frames the session has accepted but not yet emitted. Used as the
    /// backpressure readiness signal (VT has no `isReadyForMoreMediaData`).
    nonisolated func pendingFrameCount() -> Int

    /// Forces completion of all pending frames, blocking until in-flight callbacks drain.
    nonisolated func completeFrames()

    /// Tears the session down. After this call no further callbacks fire.
    nonisolated func invalidate()

    /// Whether the session is backed by a hardware-accelerated encoder.
    ///
    /// Backs the L5 assertion (AC-6: HW path is the deliverable). The mock returns `false`;
    /// the live session queries `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`.
    nonisolated func usingHardwareEncoder() -> Bool
}

// MARK: - VideoEncoderError

/// Internal session-creation failure thrown by the factory to signal the hard-fail path.
///
/// The factory throws this when a hardware HEVC `VTCompressionSession` cannot be created
/// (AC-6 / OpAC-4.1: no software fallback). The actor maps it to
/// `RecordingError.noHardwareEncoder`.
nonisolated enum VideoEncoderError: Error {
    /// VideoToolbox could not create a HW-required HEVC session, or reported
    /// `UsingHardwareAcceleratedVideoEncoder == false`.
    case hardwareEncoderUnavailable
}
