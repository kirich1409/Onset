// CameraSourceBuiltInDeliveryL5Tests.swift
// OnsetTests
//
// L5 diagnostic that empirically determines the native fps ceiling and pipeline behaviour
// of the built-in FaceTime / ISP camera on the current Mac, mirroring the MX Brio probes
// in `CameraSource4KDeliveryL5Tests.swift` and `CameraModeRecordingL5Tests.swift`.
//
// Purpose: establishes a ground-truth reference for issue #113 — the built-in camera
// reports a different format set than external USB cameras and may be subject to its own
// AVFoundation quirks on macOS. This test bypasses all project cap logic and drives a raw
// AVCaptureSession directly from the device's advertised formats.
//
// Gate: ONSET_RUN_L5_CAPTURE=1  +  TCC authorised  +  built-in wide-angle present  →  runs.
//       No Brio required.
//
// Run with:
//   ONSET_RUN_L5_CAPTURE=1 xcodebuild test \
//     -scheme Onset \
//     -destination 'platform=macOS' \
//     -configuration Debug \
//     ONLY_ACTIVE_ARCH=YES \
//     -only-testing 'Built-in camera delivery probe (issue #113)'
//
// Assertions: validity only (session started + frameCount > 0 for Test A; file exists for
// Test B). Delivered dims, fps, and FourCC are LOGGED, never asserted — the answer is unknown.
//
// swiftlint:disable file_length
// Rationale: two end-to-end raw-AVCaptureSession + full-pipeline setups cannot be split
// without scattering the load-bearing session-lifecycle ordering.

import AVFoundation
import CoreMedia
@testable import Onset
import OSLog
import Testing

// MARK: - Gate helpers

/// Returns `true` when ONSET_RUN_L5_CAPTURE=1 is set AND both camera and microphone TCC
/// authorisations have been granted.
///
/// Mirrors `l5CaptureAuthorized()` in `CameraModeRecordingL5Tests.swift` — intentionally
/// self-contained to avoid a cross-file dependency on a private function.
private func builtIn_captureAuthorized() -> Bool {
    guard ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1" else { return false }
    let video = AVCaptureDevice.authorizationStatus(for: .video)
    let audio = AVCaptureDevice.authorizationStatus(for: .audio)
    return video == .authorized && audio == .authorized
}

/// Returns `true` when all three conditions for the built-in camera raw-capture probe hold:
///
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment (explicit opt-in).
/// 2. TCC authorisation is granted for both camera and microphone.
/// 3. A `.builtInWideAngleCamera` device is present in the system.
///
/// Only `.builtInWideAngleCamera` is queried — external / continuity cameras are excluded so
/// the test is hardware-agnostic and will skip on Mac Pro or any machine without an ISP.
private func l5BuiltInEnabled() -> Bool {
    guard builtIn_captureAuthorized() else { return false }
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    )
    return !discovery.devices.isEmpty
}

/// Returns `true` when all conditions for the built-in camera full-pipeline recording hold:
///
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment.
/// 2. Camera and microphone TCC authorisations are granted.
/// 3. Screen-recording TCC is granted (required for a real screen+camera session).
/// 4. A `.builtInWideAngleCamera` device is present.
private func l5BuiltInRecordingEnabled() -> Bool {
    guard l5BuiltInEnabled() else { return false }
    return ScreenRecordingPermission().currentStatus() == .authorized
}

// MARK: - Shared logger

/// Logger for all built-in camera DIAGNOSTIC #113 entries.
///
/// Category `DIAG.113.builtin` distinguishes this suite from `DIAG.113.4K` (Brio) and from
/// the `CameraModeRecordingL5` entries.
/// Filter with:
///   log show --predicate 'subsystem == "dev.androidbroadcast.Onset" AND category == "DIAG.113.builtin"'
nonisolated private let builtInLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DIAG.113.builtin"
)

// MARK: - Built-in camera delivery probe suite

// swiftlint:disable type_body_length
// Rationale: two end-to-end AVCaptureSession setups (raw probe + full pipeline) cannot be
// collapsed without scattering the load-bearing session-lifecycle ordering.
/// Empirically determines the native fps ceiling and pipeline behaviour of the built-in
/// FaceTime / ISP camera, settling the built-in baseline for issue #113.
///
/// Test A (`builtin_nativeMaxSustainedFps`) bypasses all project cap logic and drives a raw
/// `AVCaptureSession` to measure what AVFoundation actually delivers from the ISP.
///
/// Test B (`builtin_recordsNativeFile`) drives the full `RecordingSession` pipeline and
/// verifies the camera output file dimensions via `AVAsset`.
///
/// Serialised: both tests share the built-in camera hardware and must not overlap.
@Suite("Built-in camera delivery probe (issue #113)", .serialized, .timeLimit(.minutes(10)))
struct CameraSourceBuiltInDeliveryL5Tests {
    // MARK: - Test A — raw capture probe

    // swiftlint:disable function_body_length
    /// Probes native max fps delivery from the built-in camera via a raw `AVCaptureSession`.
    ///
    /// Steps:
    /// 1. Discovers the `.builtInWideAngleCamera` device and enumerates all formats, logging
    ///    a summary with pixel dimensions, fps ranges, and FourCC for each format (capped at 20).
    /// 2. Picks the format with the highest pixel count that supports the highest available fps.
    /// 3. Builds a bare `AVCaptureSession` with a `AVCaptureVideoDataOutput` and attaches a
    ///    `Diag4KFrameCollector` delegate.
    /// 4. Under `lockForConfiguration()`, pins `activeVideoMinFrameDuration` /
    ///    `activeVideoMaxFrameDuration` to the `minFrameDuration` of the top fps range — the
    ///    only fps-pinning mechanism on macOS.
    /// 5. Runs the session for ~5 seconds, then logs delivered dims, sustained fps, FourCC,
    ///    and a histogram of inter-frame PTS deltas.
    /// 6. Asserts only run validity: `frameCount > 0`.
    @Test(
        "DIAG — built-in camera native max fps probe (issue #113)",
        .enabled(if: l5BuiltInEnabled())
    )
    func builtin_nativeMaxSustainedFps() async throws {
        let device = try Self.findBuiltIn()

        // ── 1. Enumerate and log all formats (capped to avoid log flooding) ──────
        let formats = device.formats
        let logCap = 20
        builtInLogger.notice(
            "DIAGNOSTIC #113 [builtIn] device_formats count=\(formats.count, privacy: .public)"
        )
        for (index, fmt) in formats.prefix(logCap).enumerated() {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let subType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            let fourCC = Diag4KFrameCollector.fourCCString(from: subType)
            let fpsRanges = fmt.videoSupportedFrameRateRanges
                .map { "\(Int($0.minFrameRate))–\(Int($0.maxFrameRate)) fps" }
                .joined(separator: ", ")
            builtInLogger.notice(
                """
                DIAGNOSTIC #113 [builtIn] format[\(index, privacy: .public)] \
                \(dims.width, privacy: .public)×\(dims.height, privacy: .public) \
                subtype=\(fourCC, privacy: .public) \
                fps=[\(fpsRanges, privacy: .public)]
                """
            )
        }
        if formats.count > logCap {
            builtInLogger.notice(
                """
                DIAGNOSTIC #113 [builtIn] format list truncated \
                (showing \(logCap, privacy: .public) of \(formats.count, privacy: .public))
                """
            )
        }

        // ── 2. Pick format with highest pixel count and highest fps ──────────────
        guard let topFormat = Self.pickNativeMaxFormat(from: device) else {
            builtInLogger.notice(
                "DIAGNOSTIC #113 [builtIn] no usable format found — device has no video formats"
            )
            Issue.record("Built-in camera advertises no usable video formats")
            return
        }
        let topDims = CMVideoFormatDescriptionGetDimensions(topFormat.formatDescription)
        let topFpsRange = topFormat.videoSupportedFrameRateRanges
            .max { $0.maxFrameRate < $1.maxFrameRate }
        let topMaxFps = topFpsRange?.maxFrameRate ?? 0
        builtInLogger.notice(
            """
            DIAGNOSTIC #113 [builtIn] selected format \
            \(topDims.width, privacy: .public)×\(topDims.height, privacy: .public) \
            maxFps=\(topMaxFps, privacy: .public)
            """
        )

        // ── 3. Build raw AVCaptureSession ────────────────────────────────────────
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            Issue.record("Cannot add built-in camera input to AVCaptureSession")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        let queue = DispatchQueue(label: "dev.androidbroadcast.Onset.builtin.diag")
        let collector = Diag4KFrameCollector()
        output.setSampleBufferDelegate(collector, queue: queue)
        guard session.canAddOutput(output) else {
            Issue.record("Cannot add AVCaptureVideoDataOutput to session")
            return
        }
        session.addOutput(output)

        // ── 4. Lock configuration and pin format + fps ───────────────────────────
        try device.lockForConfiguration()
        device.activeFormat = topFormat
        // Pin to the top fps range's minFrameDuration (the shortest the device will accept
        // for that range). Hand-building CMTimeMake(1, 60) would cause NSInvalidArgumentException
        // on cameras that report NTSC top rates (~59.94) instead of exactly 60.
        if let range = topFpsRange {
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }
        device.unlockForConfiguration()

        // ── 5. Run session for ~5 seconds ────────────────────────────────────────
        let durationSeconds = 5
        session.startRunning()
        defer { session.stopRunning() }

        try await Task.sleep(for: .seconds(durationSeconds))

        let snap = collector.snapshot

        // ── 6. Log delivery results ──────────────────────────────────────────────
        builtInLogger.notice(
            """
            DIAGNOSTIC #113 [builtIn] delivered \
            frameCount=\(snap.frameCount, privacy: .public) \
            dims=\(snap.lastWidth, privacy: .public)×\(snap.lastHeight, privacy: .public) \
            fourCC=\(snap.lastFourCC, privacy: .public)
            """
        )

        if snap.ptsValues.count >= 2 {
            let deltaStats = Diag4KDeltaStats(from: snap)
            builtInLogger.notice(
                """
                DIAGNOSTIC #113 [builtIn] pts_fps=\(deltaStats.ptsFps, privacy: .public) \
                mean_ms=\(deltaStats.meanMs, privacy: .public) \
                min_ms=\(deltaStats.minMs, privacy: .public) \
                max_ms=\(deltaStats.maxMs, privacy: .public) \
                std_ms=\(deltaStats.stdMs, privacy: .public)
                """
            )
            builtInLogger.notice(
                """
                DIAGNOSTIC #113 [builtIn] histogram \
                below14=\(deltaStats.histBelow14, privacy: .public) \
                14to20=\(deltaStats.hist14to20, privacy: .public) \
                20to40=\(deltaStats.hist20to40, privacy: .public) \
                40to60=\(deltaStats.hist40to60, privacy: .public) \
                above60=\(deltaStats.histAbove60, privacy: .public)
                """
            )
        }

        // ── 7. Validity assertion ────────────────────────────────────────────────
        #expect(snap.frameCount > 0, "Built-in camera delivered zero frames — session may have failed to start")
    }

    // swiftlint:enable function_body_length

    // MARK: - Test B — full pipeline recording

    // swiftlint:disable function_body_length
    /// Records ~8s through the full `RecordingSession` pipeline using the built-in camera at
    /// its native max format and asserts the output camera file has a non-empty video track.
    ///
    /// The test selects the highest-pixel-count format that also has the highest available fps
    /// from `camera.formats` (the project `CameraDevice` representation), bypassing
    /// `CameraFormatSelector` so the built-in camera is not artificially capped. Dimensions and
    /// fps are logged; only file existence and a non-zero track duration are asserted.
    ///
    /// Ground-truth for issue #113: verifies the full pipeline (capture → encode → mux) accepts
    /// the built-in camera at its native format without crashing or producing an empty file.
    @Test(
        "DIAG — built-in camera records a native-format camera file (issue #113)",
        .enabled(if: l5BuiltInRecordingEnabled())
    )
    func builtin_recordsNativeFile() async throws {
        let config = RecordingConfiguration.mvpDefault

        // ── 1. Discover display ──────────────────────────────────────────────────
        let displays = try await DeviceDiscovery.displays(screenAuthorized: true)
        let display = try #require(displays.first, "no display available for L5")

        // ── 2. Discover the built-in camera via DeviceDiscovery ──────────────────
        // Query [.builtInWideAngleCamera] alone to guarantee we get the ISP, not a connected
        // Continuity Camera or external USB device. cameraDeviceTypes includes external devices.
        let builtInDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let builtInUniqueID = try #require(
            builtInDiscovery.devices.first?.uniqueID,
            "No built-in wide-angle camera found — l5BuiltInRecordingEnabled() should have prevented this"
        )

        let allCameras = DeviceDiscovery.cameras(cameraAuthorized: true)
        let camera = try #require(
            allCameras.first { $0.uniqueID == builtInUniqueID },
            "Built-in CameraDevice not found in DeviceDiscovery.cameras — TCC may have been revoked"
        )

        // ── 3. Select format — highest pixel count, highest fps ──────────────────
        // Bypass CameraFormatSelector: we want the raw native maximum, not the 1080p cap.
        let format = try #require(
            Self.pickNativeCameraFormat(from: camera.formats),
            "Built-in camera advertises no usable CameraFormat entries"
        )
        let resolvedFps = Int(format.maxFps.rounded())

        builtInLogger.notice(
            """
            DIAGNOSTIC #113 [builtIn_record] \
            format=\(format.pixelWidth, privacy: .public)×\(format.pixelHeight, privacy: .public) \
            resolvedFps=\(resolvedFps, privacy: .public)
            """
        )

        // ── 4. Build ResolvedRecordingPlan ───────────────────────────────────────
        let screenW = display.pixelWidth.isMultiple(of: 2) ? display.pixelWidth : display.pixelWidth - 1
        let screenH = display.pixelHeight.isMultiple(of: 2) ? display.pixelHeight : display.pixelHeight - 1
        let plan = ResolvedRecordingPlan(
            displayID: display.displayID,
            screenWidth: screenW,
            screenHeight: screenH,
            screenFps: config.maxScreenFps,
            cameraPlan: ResolvedCameraPlan(
                width: Int(format.pixelWidth),
                height: Int(format.pixelHeight),
                fps: resolvedFps
            )
        )

        // ── 5. Wire paired output to ~/Movies/Onset/ ─────────────────────────────
        let outputDir = config.outputDirectory
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let label = "builtin"
        let screenURL = outputDir.appending(path: "Onset-L5-\(label)-\(timestamp)-screen.mp4")
        let cameraURL = outputDir.appending(path: "Onset-L5-\(label)-\(timestamp)-camera.mp4")

        let writerFactory = LiveWriterFactory(configuration: config) { kind in
            kind == .screen ? screenURL : cameraURL
        }

        builtInLogger.notice(
            "DIAGNOSTIC #113 [builtIn_record] camera_output=\(cameraURL.path(percentEncoded: false), privacy: .public)"
        )

        // ── 6. Build session — inject probe so preflight never reduces resolution ─
        let mic = DeviceDiscovery.microphones(microphoneAuthorized: true).first
        let session = RecordingSession(
            plan: plan,
            display: display,
            cameraDevice: camera,
            cameraFormat: format,
            cameraModeTargetFps: resolvedFps,
            micDevice: mic,
            config: config,
            probe: { .ok(plan) },
            writerFactory: writerFactory
        )

        // ── 7. Record ────────────────────────────────────────────────────────────
        let durationSeconds = 8
        builtInLogger.notice(
            "DIAGNOSTIC #113 [builtIn_record] recording_start dur_s=\(durationSeconds, privacy: .public)"
        )

        try await session.start(permissions: EffectivePermissions(
            screenAvailable: true,
            cameraAvailable: true,
            microphoneAvailable: mic != nil
        ))
        try await Task.sleep(for: .seconds(durationSeconds))
        let result = await session.stop()

        // ── 8. Verify output file ────────────────────────────────────────────────
        let cameraFileExists = FileManager.default.fileExists(atPath: cameraURL.path)
        #expect(cameraFileExists, "camera output file does not exist at \(cameraURL.lastPathComponent)")
        guard cameraFileExists else { return }

        // ── 9. Inspect the camera video track ───────────────────────────────────
        let asset = AVURLAsset(url: cameraURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try #require(videoTracks.first, "no video track in camera output file")

        // Use async load() — sync properties naturalSize/nominalFrameRate are deprecated on
        // macOS 26 (warnings-as-errors), so the synchronous path fails to compile.
        let (naturalSize, nominalFrameRate) = try await videoTrack.load(
            .naturalSize,
            .nominalFrameRate
        )

        builtInLogger.notice(
            """
            DIAGNOSTIC #113 [builtIn_record] \
            naturalSize=\(Int(naturalSize.width), privacy: .public)×\(Int(naturalSize.height), privacy: .public) \
            nominalFps=\(nominalFrameRate, privacy: .public)
            """
        )

        // Dimensions are informational — the built-in camera's delivered resolution on macOS
        // is unknown; that is what this probe measures. Only file existence is asserted hard.
        #expect(
            nominalFrameRate > 0,
            "DIAGNOSTIC #113: nominalFrameRate is 0 — built-in camera video track has no timing information"
        )

        // Drop counter is informational.
        _ = result.drops
    }

    // swiftlint:enable function_body_length

    // MARK: - Static helpers

    /// Finds the first `.builtInWideAngleCamera` device from an exclusive discovery session.
    ///
    /// Queries `[.builtInWideAngleCamera]` only — external and Continuity Camera devices are
    /// excluded so the result is always the Mac's own ISP, regardless of what USB cameras are
    /// attached.
    ///
    /// - Throws: `BuiltInSetupError.noBuiltIn` when no built-in wide-angle camera is present.
    private static func findBuiltIn() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first else {
            throw BuiltInSetupError.noBuiltIn
        }
        return device
    }

    /// Picks the `AVCaptureDevice.Format` with the highest pixel count and, among ties, the
    /// highest available `maxFrameRate` — the native maximum the ISP will deliver.
    ///
    /// Selection uses pixel area (`width * height`) as the primary key and `maxFrameRate` as
    /// the tiebreaker, matching the built-in probe intent of "how high can this camera actually go".
    ///
    /// - Returns: The selected format, or `nil` if `device.formats` is empty.
    private static func pickNativeMaxFormat(from device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.max { lhs, rhs in
            let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lPixels = Int(lDims.width) * Int(lDims.height)
            let rPixels = Int(rDims.width) * Int(rDims.height)
            if lPixels != rPixels { return lPixels < rPixels }
            let lFps = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rFps = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lFps < rFps
        }
    }

    /// Picks the `CameraFormat` (project model) with the highest pixel count and, among ties,
    /// the highest `maxFps` — used for Test B which consumes the `DeviceDiscovery` layer.
    ///
    /// `CameraFormat.pixelWidth` and `pixelHeight` are `Int32`; `maxFps` is `Double`.
    ///
    /// - Returns: The selected `CameraFormat`, or `nil` if `formats` is empty.
    private static func pickNativeCameraFormat(from formats: [CameraFormat]) -> CameraFormat? {
        formats.max { lhs, rhs in
            let lPixels = Int(lhs.pixelWidth) * Int(lhs.pixelHeight)
            let rPixels = Int(rhs.pixelWidth) * Int(rhs.pixelHeight)
            if lPixels != rPixels { return lPixels < rPixels }
            return lhs.maxFps < rhs.maxFps
        }
    }
}

// swiftlint:enable type_body_length

// MARK: - Setup errors

/// Errors thrown by the built-in camera diagnostic test setup helpers.
private enum BuiltInSetupError: Error {
    /// No `.builtInWideAngleCamera` device was found in `AVCaptureDevice.DiscoverySession`.
    ///
    /// `l5BuiltInEnabled()` should prevent this during normal test execution; a throw here
    /// indicates a transient disconnect between gate evaluation and test body.
    case noBuiltIn
}
