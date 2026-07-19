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
nonisolated struct Display {
    /// The Core Graphics display identifier.
    let displayID: CGDirectDisplayID

    /// Human-readable display name resolved from `NSScreen.localizedName` at enumeration time.
    ///
    /// Falls back to `"Встроенный дисплей"` for built-in displays (when `CGDisplayIsBuiltin`
    /// returns `true` and `NSScreen` yields no name), or `"Дисплей N"` (1-based enumeration
    /// ordinal) for external displays with no matching `NSScreen` entry.
    let name: String

    /// Physical pixel width from the display's current mode (`CGDisplayMode.pixelWidth`).
    /// 0 when no mode is available (display disconnecting, TCC race, etc.).
    let pixelWidth: Int

    /// Physical pixel height from the display's current mode (`CGDisplayMode.pixelHeight`).
    /// 0 when no mode is available.
    let pixelHeight: Int

    /// Refresh rate in Hz from `CGDisplayMode.refreshRate`. 0.0 for built-in displays.
    let refreshHz: Double
}

extension Display: Equatable {}

// MARK: - CameraFormat

/// An immutable snapshot of a single `AVCaptureDevice.Format` for a camera device.
///
/// Raw values from the format's `CMVideoFormatDescription` and its
/// `videoSupportedFrameRateRanges`. Min/max fps are the extremes across all ranges
/// in the format — the caller picks the specific target fps at session setup time.
nonisolated struct CameraFormat {
    /// Frame width in pixels (`CMVideoFormatDescriptionGetDimensions(...).width`).
    let pixelWidth: Int32

    /// Frame height in pixels (`CMVideoFormatDescriptionGetDimensions(...).height`).
    let pixelHeight: Int32

    /// Minimum frame rate across all supported ranges. 0.0 when no ranges exist.
    let minFps: Double

    /// Maximum frame rate across all supported ranges. 0.0 when no ranges exist.
    let maxFps: Double
}

extension CameraFormat: Equatable {}

// MARK: - CameraDevice

/// An immutable snapshot of a camera `AVCaptureDevice` at the moment of enumeration.
///
/// The wrapped `AVCaptureDevice` reference is deliberately excluded — holding live
/// framework objects in stored state breaks Sendable discipline and causes stale
/// references after TCC state changes. Re-query via `uniqueID` when a session needs
/// a live reference.
nonisolated struct CameraDevice {
    /// The `AVCaptureDevice.uniqueID` value — stable across app launches for the same device.
    ///
    /// **Never log this field.** Device uniqueIDs are PII-adjacent; log counts only.
    let uniqueID: String

    /// All formats advertised by the device at enumeration time.
    let formats: [CameraFormat]

    /// `true` when the device is a Continuity Camera (iPhone used as a webcam).
    ///
    /// Used to tailor UI copy — «Подключение iPhone…» vs «Подключение камеры…».
    let isContinuityCamera: Bool

    /// Creates a camera snapshot. `isContinuityCamera` defaults to `false` so existing
    /// call sites that predate Continuity-Camera labeling keep compiling.
    init(uniqueID: String, formats: [CameraFormat], isContinuityCamera: Bool = false) {
        self.uniqueID = uniqueID
        self.formats = formats
        self.isContinuityCamera = isContinuityCamera
    }
}

extension CameraDevice: Equatable {
    nonisolated static func == (lhs: CameraDevice, rhs: CameraDevice) -> Bool {
        guard lhs.uniqueID == rhs.uniqueID else { return false }
        // Avoid `lhs.formats == rhs.formats` — Array.== dispatches through the
        // Equatable protocol witness, and under InferIsolatedConformances the
        // CameraFormat: Equatable conformance is inferred @MainActor even with a
        // manual nonisolated == implementation. Direct element comparison bypasses
        // the witness table and calls CameraFormat stored-property access directly.
        // `isContinuityCamera` is intentionally excluded: it is determined by `uniqueID`
        // (transport is intrinsic per device), so comparing `uniqueID` is sufficient.
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
nonisolated struct MicrophoneDevice {
    /// The `AVCaptureDevice.uniqueID` value — stable across app launches for the same device.
    ///
    /// **Never log this field.** Device uniqueIDs are PII-adjacent; log counts only.
    let uniqueID: String

    /// `true` for the notebook's internal microphone array — every device on the
    /// built-in (`bltn`) transport EXCEPT the 3.5mm headphone-jack input.
    ///
    /// The internal mic array delivers digital silence while the lid is closed
    /// (clamshell mode with an external display), but no AVFoundation or CoreAudio
    /// property signals this — the device stays connected and non-suspended.
    /// `isBuiltIn` is the flag that lets the picker hide it while the lid is closed
    /// (see `DeviceDiscovery.microphonesAvailable(_:lidClosed:)`). It is set from
    /// `DeviceDiscovery.isBuiltInMicrophone(uniqueID:transportType:)`, a fail-safe
    /// discriminator: any `bltn`-transport mic is hidden (model-agnostic, so an
    /// internal mic whose `uniqueID` differs is never left silently recording
    /// silence), except the jack input (`BuiltInHeadphoneInputDevice`) — a physical
    /// external mic that works lid-closed and must stay `false`/visible.
    let isBuiltIn: Bool

    /// Creates a microphone snapshot.
    ///
    /// `isBuiltIn` defaults to `false` so existing call sites that pass only `uniqueID`
    /// keep compiling.
    init(uniqueID: String, isBuiltIn: Bool = false) {
        self.uniqueID = uniqueID
        self.isBuiltIn = isBuiltIn
    }
}

extension MicrophoneDevice: Equatable {}
