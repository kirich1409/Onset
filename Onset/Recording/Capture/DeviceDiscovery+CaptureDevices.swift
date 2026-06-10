import AVFoundation
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
        return CameraDevice(uniqueID: device.uniqueID, formats: formats)
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
    /// Enumerates all connected microphone devices that are currently able to capture.
    ///
    /// Queries `AVCaptureDevice.DiscoverySession` for `.microphone` (macOS 14+).
    ///
    /// Suspended devices (`isSuspended == true`) are excluded, mirroring camera
    /// enumeration. If the built-in microphone never reports suspended (it keeps working
    /// with the lid closed on some models), the filter is a no-op — which is correct,
    /// because the device is genuinely usable then.
    ///
    /// - Parameter microphoneAuthorized: Pass `true` when the process holds microphone
    ///   permission. Pass `false` to receive an empty array without any AVFoundation calls.
    ///
    /// - Returns: One `MicrophoneDevice` snapshot per non-suspended device.
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
        let devices = availableDevices.map { device in
            Self.makeMicrophoneDevice(from: device)
        }

        // PII policy: log counts only, never device names or uniqueIDs.
        discoveryDeviceLogger.info(
            """
            Microphone enumeration complete — count: \(devices.count), \
            suspended filtered: \(allDevices.count - availableDevices.count)
            """
        )
        return devices
    }

    // MARK: - Microphone pure mapper (testability seam)

    /// Maps a live `AVCaptureDevice` (audio) to a `MicrophoneDevice` snapshot.
    nonisolated static func makeMicrophoneDevice(from device: AVCaptureDevice) -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: device.uniqueID)
    }
}
