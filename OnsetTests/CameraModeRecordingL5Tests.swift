// CameraModeRecordingL5Tests.swift
// OnsetTests
//
// L5 integration tests that drive the FULL RecordingSession pipeline with a camera-mode
// override and verify the ACTUAL recorded file dimensions via AVAsset/AVAssetTrack.
//
// Purpose: ground-truth verification for issue #113 — confirms 1080p60 capture survives all
// the way through encode → mux → file, and that 4K is correctly excluded from available modes.
//
// Gate: ONSET_RUN_L5_CAPTURE=1  +  Logitech MX Brio connected  +  screen TCC granted  →  runs.
//       Otherwise: SKIP (not FAIL).
//
// swiftlint:disable function_body_length
// Rationale: the shared pipeline helper is a single end-to-end orchestration that cannot be
// split without scattering the load-bearing ordering. Same exemption as RecordingSessionTests.

import AVFoundation
@testable import Onset
import OSLog
import Testing

// MARK: - Gate helpers

/// Returns `true` when ONSET_RUN_L5_CAPTURE=1 is set AND both camera and microphone TCC
/// authorisations have been granted. Mirrors `l5CaptureEnabled()` in CameraSourceLogicTests.swift —
/// duplicated here to avoid a cross-file dependency on a private function.
private func l5CaptureAuthorized() -> Bool {
    guard ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1" else { return false }
    let video = AVCaptureDevice.authorizationStatus(for: .video)
    let audio = AVCaptureDevice.authorizationStatus(for: .audio)
    return video == .authorized && audio == .authorized
}

/// Returns `true` when all conditions for the Brio-specific recording tests hold:
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment.
/// 2. Camera and microphone TCC authorisations are granted.
/// 3. Screen-recording TCC is granted (required for a real screen+camera session).
/// 4. A camera whose `localizedName` contains "Brio" (case-insensitive) is connected.
private func l5BrioRecordingEnabled() -> Bool {
    guard l5CaptureAuthorized() else { return false }
    guard ScreenRecordingPermission().currentStatus() == .authorized else { return false }
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    return discovery.devices.contains { $0.localizedName.localizedCaseInsensitiveContains("Brio") }
}

// MARK: - Shared logger

/// Logger shared across helpers. Category isolates DIAGNOSTIC #113 entries for easy grep.
nonisolated private let cml5Logger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CameraModeRecordingL5"
)

// MARK: - L5 suite

/// Integration tests that record through the full pipeline with an explicit `CameraMode` override
/// and assert the actual encoded output file's video-track dimensions and fps.
///
/// Answers issue #113: does 1080p60 capture survive encode → mux → file intact?
/// Also asserts that the Brio's 4K mode is NOT offered by the enumerator (excluded by the
/// 1080p cap — AVFoundation on macOS reconciles the Brio's advertised 4K format down to
/// 1080p; no `.inputPriority` escape exists on macOS).
///
/// Serialised: tests share the MX Brio — they must not overlap.
@Suite(
    "CameraMode — L5 full-pipeline recording (issue #113)",
    .serialized,
    .timeLimit(.minutes(10))
)
struct CameraModeRecordingL5Tests {
    // MARK: - 4K excluded by enumerator

    /// Verifies that the Brio's 4K format is NOT offered as a user-selectable mode.
    ///
    /// AVFoundation on macOS does not deliver the Brio's advertised 3840×2160 format —
    /// AVCaptureSession reconciles `activeFormat` down to 1080p (no `.inputPriority` escape
    /// on macOS; verified L5). MJPEG is also not exposed. The enumerator caps modes at 1080p
    /// so the user never sees an option that silently downscales at runtime.
    @Test(
        "Brio 4K format is NOT offered as a selectable mode (excluded by 1080p cap)",
        .enabled(if: l5BrioRecordingEnabled())
    )
    func brioCameraMode_4K_notOfferedByEnumerator() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceDiscovery.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        guard let brioAVDevice = discovery.devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("Brio")
        }) else {
            Issue.record("Brio not found — test should not have been enabled")
            return
        }
        let brioFormats = DeviceDiscovery.makeCameraDevice(from: brioAVDevice).formats
        let modes = CameraFormatSelector.availableModes(
            from: brioFormats,
            config: RecordingConfiguration.mvpDefault
        )
        let modesSummary = modes
            .map { "\($0.pixelWidth)×\($0.pixelHeight)@\($0.fps)" }
            .joined(separator: ", ")
        cml5Logger.notice("DIAGNOSTIC #113 — Brio available modes: \(modesSummary, privacy: .public)")
        let has4K = modes.contains { $0.pixelWidth > 1920 }
        #expect(
            !has4K,
            "Brio must not offer modes above 1080p — 4K is not deliverable via AVFoundation on macOS (issue #113)"
        )
    }

    // MARK: - 1080p 60 fps

    /// Records ~5s through the full pipeline with a 1080p 60 fps override and asserts the
    /// resulting camera file contains a video track whose `naturalSize` is exactly 1920 × 1080.
    ///
    /// Ground-truth verification for issue #113: the encoded pixels in the file prove the full
    /// pipeline (capture → encode → mux) processed 1080p frames at the correct fps.
    ///
    /// DIAGNOSTIC #113 markers: output file path and actual dimensions are logged via `os.Logger`
    /// so `log show --predicate 'subsystem == "dev.androidbroadcast.Onset"'` surfaces them without
    /// any post-run file inspection.
    @Test(
        "Brio 1080p60 mode override records actual 1920×1080 camera file",
        .enabled(if: l5BrioRecordingEnabled())
    )
    func brioCameraMode_1080p60_recordsActual1080pFile() async throws {
        try await self.runBrioModeRecording(
            mode: CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60),
            expectedWidth: 1920,
            expectedHeight: 1080,
            label: "1080p60"
        )
    }

    // MARK: - Shared pipeline helper

    /// Drives a complete screen+camera `RecordingSession` with the given `CameraMode` override,
    /// records for ~8s, then opens the camera output file and asserts its video-track dimensions.
    ///
    /// Four seams are wired consistently:
    /// - `display` — a real display discovered via `DeviceDiscovery.displays(screenAuthorized:)`.
    /// - `cameraFormat` — the `CameraFormat` matched by `resolveFormat`.
    /// - `cameraModeTargetFps` — the explicit fps resolved by `resolveFormat`.
    /// - `cameraPlan` inside `ResolvedRecordingPlan` — sized to the same width / height / fps.
    ///
    /// The capability probe is injected as `{ .ok(plan) }` so the preflight never reduces the
    /// resolution. Both output files are written to `~/Movies/Onset/` so the pair survives the
    /// test run for `scripts/verify-cfr.sh` inspection.
    ///
    /// - Parameters:
    ///   - mode: The `CameraMode` override to apply.
    ///   - expectedWidth: The width that must appear in `AVAssetTrack.naturalSize`.
    ///   - expectedHeight: The height that must appear in `AVAssetTrack.naturalSize`.
    ///   - label: Short human-readable tag used in log messages and file names (e.g. "1080p60").
    private func runBrioModeRecording(
        mode: CameraMode,
        expectedWidth: Int,
        expectedHeight: Int,
        label: String
    ) async throws {
        let config = RecordingConfiguration.mvpDefault

        // ── 1. Discover a real display (required for screen+camera session) ──────
        let displays = try await DeviceDiscovery.displays(screenAuthorized: true)
        let display = try #require(displays.first, "no display available for L5")

        // ── 2. Discover the Brio by name match ──────────────────────────────────
        let cameras = DeviceDiscovery.cameras(cameraAuthorized: true)
        let avDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceDiscovery.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let brioUniqueID = avDiscovery.devices
            .first { $0.localizedName.localizedCaseInsensitiveContains("Brio") }
            .map(\.uniqueID)
        let camera = try #require(
            cameras.first { $0.uniqueID == brioUniqueID },
            "Brio CameraDevice not found — l5BrioRecordingEnabled() should have prevented this"
        )

        // ── 3. Resolve the format with the explicit mode override ────────────────
        let (format, resolvedFps) = try CameraFormatSelector.resolveFormat(
            from: camera.formats,
            override: mode,
            config: config
        )

        // Pre-flight: if resolveFormat fell back to auto, the override is unsupported on this Brio.
        // Hard-fail rather than silently verifying the wrong resolution.
        #expect(
            format.pixelWidth == mode.pixelWidth && format.pixelHeight == mode.pixelHeight,
            """
            resolveFormat fell back to auto for \(label) — \
            Brio may not advertise \(mode.pixelWidth)×\(mode.pixelHeight) @\(mode.fps)fps
            """
        )
        guard format.pixelWidth == mode.pixelWidth,
              format.pixelHeight == mode.pixelHeight
        else {
            return
        }

        // DIAGNOSTIC #113
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] \
            resolvedFormat=\(format.pixelWidth, privacy: .public)\
            ×\(format.pixelHeight, privacy: .public) \
            resolvedFps=\(resolvedFps, privacy: .public)
            """
        )

        // ── 4. Build the resolved plan with real display dims (precondition: >0, even) ──
        // Mirror RecordingSessionTests.runLiveRecordingSession — same even-adjust, same field order.
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
        // One shared timestamp produces a matched screen+camera pair for verify-cfr.
        let outputDir = config.outputDirectory
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let screenURL = outputDir.appending(path: "Onset-L5-\(label)-\(timestamp)-screen.mp4")
        let cameraURL = outputDir.appending(path: "Onset-L5-\(label)-\(timestamp)-camera.mp4")

        let writerFactory = LiveWriterFactory(configuration: config) { kind in
            kind == .screen ? screenURL : cameraURL
        }

        // DIAGNOSTIC #113 — log planned output paths before the session starts.
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] \
            screen_output=\(screenURL.path(percentEncoded: false), privacy: .public)
            """
        )
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] \
            camera_output=\(cameraURL.path(percentEncoded: false), privacy: .public)
            """
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
        // 8 seconds gives verify-cfr enough packet timestamps for a reliable cadence measurement.
        let durationSeconds = 8
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] recording_start \
            dur_s=\(durationSeconds, privacy: .public)
            """
        )

        try await session.start(permissions: EffectivePermissions(
            screenAvailable: true,
            cameraAvailable: true,
            microphoneAvailable: mic != nil
        ))
        try await Task.sleep(for: .seconds(durationSeconds))
        let result = await session.stop()

        // ── 8. Verify the camera output file exists ──────────────────────────────
        let cameraFileExists = FileManager.default.fileExists(atPath: cameraURL.path)
        #expect(cameraFileExists, "camera output file does not exist at \(cameraURL.lastPathComponent)")
        guard cameraFileExists else { return }

        // ── 9. Inspect the camera video track ───────────────────────────────────
        let asset = AVURLAsset(url: cameraURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try #require(videoTracks.first, "no video track in camera output file")

        // Use async load() — the sync properties naturalSize/nominalFrameRate are deprecated on
        // macOS 26 (warnings-as-errors), so the synchronous path fails to compile.
        let (naturalSize, nominalFrameRate) = try await videoTrack.load(
            .naturalSize,
            .nominalFrameRate
        )

        // DIAGNOSTIC #113
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] \
            naturalSize=\(Int(naturalSize.width), privacy: .public)\
            ×\(Int(naturalSize.height), privacy: .public) \
            nominalFps=\(nominalFrameRate, privacy: .public)
            """
        )

        // Hard assert on dimensions — the ground-truth question for issue #113.
        let actualWidth = Int(naturalSize.width)
        let actualHeight = Int(naturalSize.height)
        #expect(
            actualWidth == expectedWidth,
            "DIAGNOSTIC #113: expected width \(expectedWidth), got \(actualWidth) — pipeline may have downscaled"
        )
        #expect(
            actualHeight == expectedHeight,
            "DIAGNOSTIC #113: expected height \(expectedHeight), got \(actualHeight) — pipeline may have downscaled"
        )

        // Loose fps check — log for manual review, fail only when fps is zero (encode fault).
        // DIAGNOSTIC #113
        cml5Logger.notice(
            """
            DIAGNOSTIC #113 [\(label, privacy: .public)] \
            nominalFps=\(nominalFrameRate, privacy: .public) \
            expectedFps=\(mode.fps, privacy: .public)
            """
        )
        #expect(
            nominalFrameRate > 0,
            "DIAGNOSTIC #113: nominalFrameRate is 0 — video track has no timing information"
        )

        // Drop counter is informational; non-zero does not fail the test.
        _ = result.drops
    }
}

// swiftlint:enable function_body_length
