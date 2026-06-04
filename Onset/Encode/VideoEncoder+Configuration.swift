// VideoEncoder+Configuration.swift
// Onset
//
// U3 of #31 — encoder session-property configuration, split out of VideoEncoder.swift to keep
// that file within the project's length limit (matching the CameraSource+SessionSetup.swift
// pattern). Maps the pure U1 `VTEncoderSettings` to VideoToolbox property keys.
//
// Methods are actor-isolated (default isolation under SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor is overridden by the `actor` declaration) and `internal` rather than `private`
// because they live in a separate file from the primary `actor VideoEncoder` body; the
// project uses the same convention for CameraSource's session-setup extension.

import CoreMedia
import os
import VideoToolbox

extension VideoEncoder {
    // MARK: - Session configuration

    /// Applies all mandatory encoder properties to a freshly created session.
    ///
    /// - Throws: `RecordingError.encoderSetupFailed` if any mandatory property cannot be set.
    ///   The DataRateLimits property is the ONLY exception: a `kVTPropertyNotSupportedErr`
    ///   there falls back to AverageBitRate-only with an `os.Logger.warning` (documented on
    ///   `RecordingConfiguration` → "DataRateLimits fallback").
    func configure(session: any CompressionSession) throws {
        try self.setRequired(session, kVTCompressionPropertyKey_RealTime, self.settings.realTime as CFBoolean)
        try self.setRequired(
            session,
            kVTCompressionPropertyKey_ProfileLevel,
            self.settings.profileLevel.vtProfileLevel
        )
        try self.setRequired(
            session,
            kVTCompressionPropertyKey_AllowFrameReordering,
            self.settings.allowFrameReordering as CFBoolean
        )
        try self.setRequired(
            session,
            kVTCompressionPropertyKey_AverageBitRate,
            self.settings.averageBitRate as CFNumber
        )
        // GOP: duration key (seconds) avoids fps-rounding drift vs the frame-count key.
        try self.setRequired(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            self.settings.maxKeyFrameIntervalDurationSeconds as CFNumber
        )
        try self.setColor(session)
        self.setDataRateLimits(session)
    }

    /// Sets a mandatory property; throws `RecordingError.encoderSetupFailed` on failure.
    func setRequired(_ session: any CompressionSession, _ key: CFString, _ value: CFTypeRef) throws {
        let status = session.setProperty(key: key, value: value)
        guard status == noErr else {
            self.logger.error("Failed to set encoder property \(key) — status \(status)")
            // A property-set failure is NOT hardware unavailability — surface the specific key
            // and status (F8) rather than mislabelling it `hardwareEncoderUnavailable`.
            throw RecordingError.encoderSetupFailed(
                VideoEncoderError.propertySetFailed(key: key as String, status: status)
            )
        }
    }

    /// Sets the Rec.709 SDR color metadata (mandatory — AC-4).
    func setColor(_ session: any CompressionSession) throws {
        // The pure enums only model Rec.709 today; map each to its CMFormatDescription
        // constant. A `switch` keeps the mapping exhaustive if more cases are added later.
        let primaries: CFString
        switch self.settings.colorPrimaries {
        case .rec709: primaries = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        }
        let transfer: CFString
        switch self.settings.transferFunction {
        case .rec709: transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        let matrix: CFString
        switch self.settings.yCbCrMatrix {
        case .rec709: matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }

        try self.setRequired(session, kVTCompressionPropertyKey_ColorPrimaries, primaries)
        try self.setRequired(session, kVTCompressionPropertyKey_TransferFunction, transfer)
        try self.setRequired(session, kVTCompressionPropertyKey_YCbCrMatrix, matrix)
    }

    /// Sets `DataRateLimits` (peak cap) with graceful fallback.
    ///
    /// The value is a `CFArray` of alternating `[bytes, seconds]` CFNumbers — NOT bits. The
    /// peak rate (bits/s) is converted to bytes for a one-second window: `[peakBytes, 1.0]`.
    /// If the encoder returns `kVTPropertyNotSupportedErr` the encoder proceeds with
    /// AverageBitRate-only (already set) and logs a warning — this fallback is ONLY for
    /// DataRateLimits, never for HW unavailability.
    func setDataRateLimits(_ session: any CompressionSession) {
        let bitsPerByte = 8 // bits/s → bytes for a 1-second window.
        let windowSeconds = 1.0
        let peakBytesPerSecond = self.settings.peakDataRate / bitsPerByte
        let limits = [peakBytesPerSecond as CFNumber, windowSeconds as CFNumber] as CFArray
        let status = session.setProperty(key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        if status == kVTPropertyNotSupportedErr {
            self.logger.warning("DataRateLimits unsupported by encoder — falling back to AverageBitRate-only")
        } else if status != noErr {
            self.logger.warning("DataRateLimits set returned status \(status) — proceeding AverageBitRate-only")
        }
    }
}
