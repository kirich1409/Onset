import AVFoundation
import CoreAudio
import CoreMedia
import os

/// Logger is Sendable; nonisolated private let avoids a MainActor hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated private let discoveryDeviceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DeviceDiscovery.CaptureDevices"
)

// MARK: - Camera enumeration

extension DeviceDiscovery {
    /// The `AVCaptureDevice.DeviceType` values that identify camera devices on macOS 26.
    ///
    /// Covers built-in wide-angle, USB/Thunderbolt external, and Continuity Camera sources.
    /// Shared between `cameras(cameraAuthorized:)` and tests that build a discovery session
    /// for name matching so the two never diverge.
    nonisolated static let cameraDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
    ]

    /// Enumerates all connected camera devices that are currently able to capture.
    ///
    /// Queries `AVCaptureDevice.DiscoverySession` for the three macOS 26 video types:
    /// `.builtInWideAngleCamera`, `.external`, and `.continuityCamera`.
    ///
    /// Suspended devices (`isSuspended == true`) are excluded: the built-in FaceTime
    /// camera reports suspended while the notebook lid is closed and cannot deliver
    /// frames, so showing it in pickers would offer a dead device.
    ///
    /// - Parameter cameraAuthorized: Pass `true` when the process holds camera permission.
    ///   Pass `false` to receive an empty array without any AVFoundation calls.
    ///
    /// - Returns: One `CameraDevice` snapshot per non-suspended device, each containing the
    ///   device's `uniqueID` and the full list of its `AVCaptureDevice.Format` snapshots.
    nonisolated static func cameras(cameraAuthorized: Bool) -> [CameraDevice] {
        guard cameraAuthorized else {
            discoveryDeviceLogger.debug("Camera enumeration skipped — camera permission not granted")
            return []
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        let allDevices = session.devices
        let availableDevices = allDevices.filter { !$0.isSuspended }
        let devices = availableDevices.map { device in
            Self.makeCameraDevice(from: device)
        }

        // PII policy: log counts only, never device names or uniqueIDs.
        discoveryDeviceLogger.info(
            """
            Camera enumeration complete — count: \(devices.count), \
            suspended filtered: \(allDevices.count - availableDevices.count)
            """
        )
        return devices
    }

    // MARK: - Camera pure mapper (testability seam)

    /// Maps a live `AVCaptureDevice` to a `CameraDevice` snapshot.
    ///
    /// The production entry point. Delegates format mapping to `makeCameraFormat(from:)`.
    nonisolated static func makeCameraDevice(from device: AVCaptureDevice) -> CameraDevice {
        let formats = device.formats.map { Self.makeCameraFormat(from: $0) }
        return CameraDevice(
            uniqueID: device.uniqueID,
            formats: formats,
            isContinuityCamera: device.deviceType == .continuityCamera
        )
    }

    /// Maps a live `AVCaptureDevice.Format` to a `CameraFormat` snapshot.
    ///
    /// This function is the testability seam for format mapping. Unit tests call it
    /// directly with a real `AVCaptureDevice.Format` (or a synthetic one if the test
    /// can construct it); no live camera device is required.
    ///
    /// Frame-rate computation:
    /// - `minFps` = the smallest `minFrameRate` across all supported ranges.
    /// - `maxFps` = the largest `maxFrameRate` across all supported ranges.
    /// - Both are 0.0 when the format reports no frame-rate ranges.
    nonisolated static func makeCameraFormat(from format: AVCaptureDevice.Format) -> CameraFormat {
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)

        let ranges = format.videoSupportedFrameRateRanges
        let minFps = ranges.map(\.minFrameRate).min() ?? 0.0
        let maxFps = ranges.map(\.maxFrameRate).max() ?? 0.0

        return CameraFormat(
            pixelWidth: dims.width,
            pixelHeight: dims.height,
            minFps: minFps,
            maxFps: maxFps
        )
    }
}

// MARK: - Microphone enumeration

extension DeviceDiscovery {
    /// Enumerates all connected microphone devices that are currently able to capture,
    /// filtered by the current notebook lid state.
    ///
    /// Queries `AVCaptureDevice.DiscoverySession` for `.microphone` (macOS 14+).
    ///
    /// Suspended devices (`isSuspended == true`) are excluded, mirroring camera enumeration.
    /// Additionally, the built-in microphone is hidden when the lid is closed: unlike the
    /// built-in camera (which flips `isSuspended`), the built-in mic stays connected and
    /// non-suspended in clamshell mode but delivers only digital silence. Lid state from
    /// `LidState.isClosed` is the discriminating signal.
    ///
    /// - Parameter microphoneAuthorized: Pass `true` when the process holds microphone
    ///   permission. Pass `false` to receive an empty array without any AVFoundation calls.
    ///
    /// - Returns: One `MicrophoneDevice` snapshot per available, non-hidden device.
    nonisolated static func microphones(microphoneAuthorized: Bool) -> [MicrophoneDevice] {
        guard microphoneAuthorized else {
            discoveryDeviceLogger.debug("Microphone enumeration skipped — microphone permission not granted")
            return []
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        let allDevices = session.devices
        let availableDevices = allDevices.filter { !$0.isSuspended }
        let mapped = availableDevices.map { device in
            Self.makeMicrophoneDevice(from: device)
        }

        let lidClosed = LidState.isClosed
        let devices = Self.microphonesAvailable(mapped, lidClosed: lidClosed)

        // PII policy: log counts only, never device names or uniqueIDs.
        discoveryDeviceLogger.info(
            """
            Microphone enumeration complete — count: \(devices.count), \
            suspended filtered: \(allDevices.count - availableDevices.count), \
            lid-hidden: \(mapped.count - devices.count)
            """
        )
        return devices
    }

    // MARK: - Lid-state filter (pure, testable seam)

    /// Filters a mapped microphone list by the current lid state.
    ///
    /// When the lid is closed (clamshell mode with an external display), the built-in
    /// microphone is removed from the list. No AVFoundation or CoreAudio property
    /// discriminates open vs closed for the built-in mic — `isSuspended` stays `false`
    /// and CoreAudio reports the device as alive — but the audio content is digital silence.
    /// Empirically verified on macOS 26. See swarm-report/builtin-mic-clamshell-debug.md.
    ///
    /// When `lidClosed` is `false` (or on desktop Macs where `LidState.isClosed` always
    /// returns `false`), all devices are returned unchanged.
    ///
    /// - Parameters:
    ///   - devices: The full list of non-suspended `MicrophoneDevice` snapshots.
    ///   - lidClosed: `true` when `LidState.isClosed` reports the lid is shut.
    /// - Returns: The filtered list, with built-in mics removed when `lidClosed` is `true`.
    nonisolated static func microphonesAvailable(
        _ devices: [MicrophoneDevice],
        lidClosed: Bool
    )
    -> [MicrophoneDevice] {
        guard lidClosed else { return devices }
        return devices.filter { !$0.isBuiltIn }
    }

    // MARK: - Microphone pure mapper (testability seam)

    /// Maps a live `AVCaptureDevice` (audio) to a `MicrophoneDevice` snapshot.
    ///
    /// Sets `isBuiltIn` from the device's transport type: a `kAudioDeviceTransportTypeBuiltIn`
    /// transport identifies the notebook's built-in microphone.
    nonisolated static func makeMicrophoneDevice(from device: AVCaptureDevice) -> MicrophoneDevice {
        // `AVCaptureDevice.transportType` is Int32; CoreAudio's constant is UInt32.
        // Bit-pattern cast avoids a sign-extension mismatch on the comparison.
        let isBuiltIn = UInt32(bitPattern: device.transportType) == UInt32(kAudioDeviceTransportTypeBuiltIn)
        return MicrophoneDevice(uniqueID: device.uniqueID, isBuiltIn: isBuiltIn)
    }
}
