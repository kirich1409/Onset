import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

// MARK: - Live VideoToolbox session factory

extension VideoEncoder {
    /// The production `SessionFactory`: creates a HW-required HEVC `VTCompressionSession`
    /// and wires its C output callback to the sink.
    ///
    /// Throws `VideoEncoderError.hardwareEncoderUnavailable` when the session cannot be
    /// created (the actor maps this to `RecordingError.noHardwareEncoder`).
    nonisolated static let liveSessionFactory: SessionFactory = { width, height, sink in
        try LiveCompressionSession(width: width, height: height, sink: sink)
    }
}

// MARK: - LiveCompressionSession

/// The production `CompressionSession` wrapping a real `VTCompressionSession`.
///
/// `@unchecked Sendable`: the wrapped `VTCompressionSessionRef` is `CM_SWIFT_NONSENDABLE`,
/// but this wrapper is created and used ONLY from inside the `VideoEncoder` actor and is
/// never shared across isolation boundaries. The actor's isolation is the synchronization.
/// `@unchecked Sendable` is required only because `SessionFactory` is `@Sendable` (it must be
/// to be stored on the actor); the value never actually escapes the actor.
nonisolated final class LiveCompressionSession: CompressionSession, @unchecked Sendable {
    private let session: VTCompressionSession
    /// Held strong for the session's lifetime so the refcon (passUnretained) stays valid;
    /// the callback recovers it via `Unmanaged.fromOpaque(...).takeUnretainedValue()`.
    private let sink: EncodedSampleSink

    private static let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "VideoEncoder.Session"
    )

    // swiftformat:disable unusedArguments
    /// The C output callback. Non-capturing (a C function pointer captures nothing): it
    /// recovers the sink from the refcon and yields any successfully compressed buffer.
    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, infoFlags, sampleBuffer in
        // swiftformat:enable unusedArguments
        guard let refcon = unsafe refcon else {
            // Nil refcon means the Unmanaged reference was lost — no sink to yield to.
            LiveCompressionSession.logger.fault("VT output callback: nil refcon — encoder sink lost, frames dropped")
            return
        }
        // Recover the sink WITHOUT consuming a retain (passUnretained on the create side).
        let sink = unsafe Unmanaged<EncodedSampleSink>.fromOpaque(refcon).takeUnretainedValue()
        // F3: each failure branch is logged distinctly rather than a single silent `return`.
        // Logging only — surfacing these to a drop channel is #35 scope.
        // `LiveCompressionSession.logger` (not `Self.`): a covariant `Self` cannot be referenced
        // from a static stored-property initializer.
        guard status == noErr else {
            LiveCompressionSession.logger.error("Encode output callback failed: status \(status) — sample dropped")
            return
        }
        guard !infoFlags.contains(.frameDropped) else {
            LiveCompressionSession.logger.warning("Encode output callback reported .frameDropped — sample dropped")
            return
        }
        guard let sampleBuffer else {
            LiveCompressionSession.logger.error("Encode output callback: noErr but nil sampleBuffer — sample dropped")
            return
        }
        sink.yield(sampleBuffer: sampleBuffer)
    }

    nonisolated init(width: Int32, height: Int32, sink: EncodedSampleSink) throws {
        self.sink = sink

        let encoderSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true as CFBoolean,
        ] as CFDictionary

        var created: VTCompressionSession?
        // `unsafe`: VTCompressionSessionCreate has raw-pointer params (refcon, out-pointer)
        // under SWIFT_STRICT_MEMORY_SAFETY = YES. passUnretained: the sink is owned strong by
        // this wrapper, so its lifetime covers every callback; no manual release needed.
        let refcon = unsafe Unmanaged.passUnretained(sink).toOpaque()
        let status = unsafe VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: refcon,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            Self.logger.error("VTCompressionSessionCreate (HW-required HEVC) failed: \(status)")
            throw VideoEncoderError.hardwareEncoderUnavailable
        }
        self.session = created
    }

    nonisolated func setProperty(key: CFString, value: CFTypeRef) -> OSStatus {
        // VTSessionSetProperty takes (VTSessionRef, CFString, CFTypeRef?) — no raw pointer.
        VTSessionSetProperty(self.session, key: key, value: value)
    }

    nonisolated func encodeFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> OSStatus {
        // We pass nil for both raw-pointer params (sourceFrameRefcon, infoFlagsOut) — the sink
        // is recovered from the session-level refcon, not per-frame — so no unsafe pointer is
        // formed at the call site and no `unsafe` annotation is required.
        VTCompressionSessionEncodeFrame(
            self.session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    nonisolated func pendingFrameCount() -> Int {
        var value: CFTypeRef?
        // `unsafe`: VTSessionCopyProperty writes a retained CFTypeRef via a void* out-pointer.
        // Mirrors the pattern in CapabilityProbe.queryUsingHardwareEncoder.
        let status = unsafe withUnsafeMutablePointer(to: &value) { ptr in
            unsafe VTSessionCopyProperty(
                self.session,
                key: kVTCompressionPropertyKey_NumberOfPendingFrames,
                allocator: nil,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        guard status == noErr, let value, CFGetTypeID(value) == CFNumberGetTypeID() else {
            // F4: DELIBERATE fail-open. A RealTime encoder should keep the pipeline flowing on a
            // transient property-query glitch rather than stall by failing closed — returning 0
            // lets submission proceed (the backpressure gate is skipped this frame). Logged so a
            // persistent failure is visible.
            Self.logger.warning("NumberOfPendingFrames query failed: status \(status) — assuming 0 (fail-open)")
            return 0
        }
        let number = unsafe unsafeDowncast(value, to: CFNumber.self)
        var result = 0
        // `unsafe`: CFNumberGetValue writes through a void* out-pointer.
        unsafe CFNumberGetValue(number, .intType, &result)
        return result
    }

    nonisolated func completeFrames() {
        VTCompressionSessionCompleteFrames(self.session, untilPresentationTimeStamp: .invalid)
    }

    nonisolated func invalidate() {
        VTCompressionSessionInvalidate(self.session)
    }

    nonisolated func usingHardwareEncoder() -> Bool {
        var value: CFTypeRef?
        // `unsafe`: VTSessionCopyProperty writes a retained CFTypeRef via a void* out-pointer.
        // Mirrors CapabilityProbe.queryUsingHardwareEncoder.
        let status = unsafe withUnsafeMutablePointer(to: &value) { ptr in
            unsafe VTSessionCopyProperty(
                self.session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        guard status == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return false
        }
        return unsafe CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
}
