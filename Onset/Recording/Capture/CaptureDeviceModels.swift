import CoreGraphics

// MARK: - Display

/// An immutable snapshot of a connected display at the moment of enumeration.
///
/// Pixel dimensions come from `CGDisplayModeRef` — always in physical pixels, not points.
/// `SCDisplay.width`/`.height` are in **points** and are intentionally ignored here.
///
/// `refreshHz` is the raw value from `CGDisplayMode.refreshRate`. It is 0.0 for
/// Apple built-in displays (Liquid Retina, Pro Display XDR, etc.) — the OS reports 0
/// because the refresh rate is variable. Callers must not substitute a default value;
/// carry 0.0 faithfully so downstream logic can distinguish "unknown" from a true 0-Hz result.
nonisolated struct Display: Sendable {
    /// The Core Graphics display identifier.
    let displayID: CGDirectDisplayID

    /// Physical pixel width from the display's current mode (`CGDisplayMode.pixelWidth`).
    /// 0 when no mode is available (display disconnecting, TCC race, etc.).
    let pixelWidth: Int

    /// Physical pixel height from the display's current mode (`CGDisplayMode.pixelHeight`).
    /// 0 when no mode is available.
    let pixelHeight: Int

    /// Refresh rate in Hz from `CGDisplayMode.refreshRate`. 0.0 for built-in displays.
    let refreshHz: Double
}

extension Display: Equatable {
    nonisolated static func == (lhs: Display, rhs: Display) -> Bool {
        lhs.displayID == rhs.displayID &&
            lhs.pixelWidth == rhs.pixelWidth &&
            lhs.pixelHeight == rhs.pixelHeight &&
            lhs.refreshHz == rhs.refreshHz
    }
}

// MARK: - CameraFormat

/// An immutable snapshot of a single `AVCaptureDevice.Format` for a camera device.
///
/// Raw values from the format's `CMVideoFormatDescription` and its
/// `videoSupportedFrameRateRanges`. Min/max fps are the extremes across all ranges
/// in the format — the caller picks the specific target fps at session setup time.
nonisolated struct CameraFormat: Sendable {
    /// Frame width in pixels (`CMVideoFormatDescriptionGetDimensions(...).width`).
    let pixelWidth: Int32

    /// Frame height in pixels (`CMVideoFormatDescriptionGetDimensions(...).height`).
    let pixelHeight: Int32

    /// Minimum frame rate across all supported ranges. 0.0 when no ranges exist.
    let minFps: Double

    /// Maximum frame rate across all supported ranges. 0.0 when no ranges exist.
    let maxFps: Double
}

extension CameraFormat: Equatable {
    nonisolated static func == (lhs: CameraFormat, rhs: CameraFormat) -> Bool {
        lhs.pixelWidth == rhs.pixelWidth &&
            lhs.pixelHeight == rhs.pixelHeight &&
            lhs.minFps == rhs.minFps &&
            lhs.maxFps == rhs.maxFps
    }
}

// MARK: - CameraDevice

/// An immutable snapshot of a camera `AVCaptureDevice` at the moment of enumeration.
///
/// The wrapped `AVCaptureDevice` reference is deliberately excluded — holding live
/// framework objects in stored state breaks Sendable discipline and causes stale
/// references after TCC state changes. Re-query via `uniqueID` when a session needs
/// a live reference.
nonisolated struct CameraDevice: Sendable {
    /// The `AVCaptureDevice.uniqueID` value — stable across app launches for the same device.
    ///
    /// **Never log this field.** Device uniqueIDs are PII-adjacent; log counts only.
    let uniqueID: String

    /// All formats advertised by the device at enumeration time.
    let formats: [CameraFormat]
}

extension CameraDevice: Equatable {
    nonisolated static func == (lhs: CameraDevice, rhs: CameraDevice) -> Bool {
        guard lhs.uniqueID == rhs.uniqueID else { return false }
        // Avoid `lhs.formats == rhs.formats` — Array.== dispatches through the
        // Equatable protocol witness, and under InferIsolatedConformances the
        // CameraFormat: Equatable conformance is inferred @MainActor even with a
        // manual nonisolated == implementation. Direct element comparison bypasses
        // the witness table and calls CameraFormat stored-property access directly.
        guard lhs.formats.count == rhs.formats.count else { return false }
        return zip(lhs.formats, rhs.formats).allSatisfy { pair in
            let (lhs, rhs) = pair
            return lhs.pixelWidth == rhs.pixelWidth
                && lhs.pixelHeight == rhs.pixelHeight
                && lhs.minFps == rhs.minFps
                && lhs.maxFps == rhs.maxFps
        }
    }
}

// MARK: - MicrophoneDevice

/// An immutable snapshot of a microphone `AVCaptureDevice` at the moment of enumeration.
///
/// Same design rationale as `CameraDevice` — no live framework references.
nonisolated struct MicrophoneDevice: Sendable {
    /// The `AVCaptureDevice.uniqueID` value — stable across app launches for the same device.
    ///
    /// **Never log this field.** Device uniqueIDs are PII-adjacent; log counts only.
    let uniqueID: String
}

extension MicrophoneDevice: Equatable {
    nonisolated static func == (lhs: MicrophoneDevice, rhs: MicrophoneDevice) -> Bool {
        lhs.uniqueID == rhs.uniqueID
    }
}
