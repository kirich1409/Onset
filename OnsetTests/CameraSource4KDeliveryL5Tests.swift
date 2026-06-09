// CameraSource4KDeliveryL5Tests.swift
// OnsetTests
//
// L5 diagnostic that empirically determines whether AVFoundation can deliver real
// 4K (3840×2160) CVPixelBuffers from a Logitech MX Brio on macOS, bypassing all
// project cap logic (CameraFormatSelector, availableModes, pickBestFormat).
//
// Purpose: settles issue #113 — the assumption that 4K is not deliverable via
// AVFoundation on macOS has not been empirically tested against a raw AVCaptureSession.
// This test builds a raw session directly from device.formats, sets activeFormat or
// sessionPreset, and logs what actually arrives from the sensor.
//
// Gate: ONSET_RUN_L5_CAPTURE=1  +  TCC authorized  +  Brio connected  →  runs.
//       Otherwise: SKIP (not FAIL).
//
// Run with:
//   ONSET_RUN_L5_CAPTURE=1 xcodebuild test \
//     -scheme Onset \
//     -destination 'platform=macOS' \
//     -configuration Debug \
//     ONLY_ACTIVE_ARCH=YES \
//     -only-testing '4K delivery probe (issue #113)'
//
// Assertions: ONLY run validity (session started + frameCount > 0).
// Delivered dims are LOGGED, never asserted — the answer is unknown; that is the point.
//
// swiftlint:disable file_length
// Rationale: three end-to-end AVCaptureSession setups (activeFormat, preset, 1080p60 paths) cannot
// be split without scattering the load-bearing session-lifecycle ordering.

import AVFoundation
import CoreMedia
@testable import Onset
import OSLog
import Testing

// MARK: - Gate helpers

/// Returns `true` when the process holds TCC authorisation for both camera and microphone.
///
/// Duplicated from `CameraModeRecordingL5Tests` — intentionally self-contained to avoid
/// a cross-file dependency on a private function.
private func diag4K_captureAuthorized() -> Bool {
    let video = AVCaptureDevice.authorizationStatus(for: .video)
    let audio = AVCaptureDevice.authorizationStatus(for: .audio)
    return video == .authorized && audio == .authorized
}

/// Returns `true` when the three conditions for this Brio-specific probe all hold:
///
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set in the environment (explicit opt-in).
/// 2. TCC authorisation is granted for both camera and microphone.
/// 3. A connected camera whose `localizedName` contains "Brio" (case-insensitive) exists.
///
/// Condition 3 produces a genuine SKIP on machines without the Brio — not a failure.
private func diag4K_brioGateEnabled() -> Bool {
    guard ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1" else { return false }
    guard diag4K_captureAuthorized() else { return false }
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    return discovery.devices.contains { $0.localizedName.localizedCaseInsensitiveContains("Brio") }
}

// MARK: - Shared logger

/// Logger for all DIAGNOSTIC #113 4K-delivery entries.
///
/// Category `DIAG.113.4K` distinguishes this probe from the existing `DIAG.113` entries
/// in `CameraSourceLogicTests.swift` and from the `CameraModeRecordingL5` suite.
/// Filter with: `log show --predicate 'subsystem == "dev.androidbroadcast.Onset" AND category == "DIAG.113.4K"'`
nonisolated private let diag4KLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DIAG.113.4K"
)

// Shared collector types (Diag4KFrameSnapshot, DeltaBucket, Diag4KDeltaStats,
// Diag4KFrameCollector) live in DiagFrameCollector.swift — internal to OnsetTests.

// MARK: - 4K delivery probe suite

// swiftlint:disable type_body_length
// Rationale: three end-to-end AVCaptureSession setups (activeFormat, preset, 1080p60 paths) cannot
// be collapsed without scattering the load-bearing session-lifecycle ordering.
/// Empirically determines whether AVFoundation can deliver real 4K (3840×2160) frames
/// from a Logitech MX Brio on macOS, settling issue #113.
///
/// Each test builds a raw `AVCaptureSession` directly from `device.formats` — bypassing
/// all project cap logic (`CameraFormatSelector`, `availableModes`, `pickBestFormat`).
/// Both tests log the delivered buffer dimensions, fps, and FourCC via `os.Logger`.
/// Assertions verify ONLY that the session started and frames arrived; the delivered
/// resolution is NOT asserted (the answer is unknown — that is the point of this probe).
///
/// Serialised: both tests share the MX Brio hardware and must not overlap.
@Suite("4K delivery probe (issue #113)", .serialized, .timeLimit(.minutes(5)))
struct CameraSource4KDeliveryL5Tests {
    // MARK: - Test 1 — setActiveFormat path

    // swiftlint:disable function_body_length
    /// Probes 4K delivery via `AVCaptureDevice.activeFormat` set under `lockForConfiguration()`.
    ///
    /// Steps:
    /// 1. Discover the Brio in `device.formats` and select the first 3840×2160 entry that
    ///    supports ≥30 fps. If no 4K format exists in the hardware list, records a finding
    ///    and returns — the absence itself is a valid diagnostic result.
    /// 2. Builds a bare `AVCaptureSession`, adds the Brio `AVCaptureDeviceInput`, adds a
    ///    `AVCaptureVideoDataOutput` with 420v pixel format.
    /// 3. Under `lockForConfiguration()`, sets `activeFormat` and pins `activeVideoMinFrameDuration`
    ///    / `activeVideoMaxFrameDuration` to 30 fps — the only fps-pinning mechanism on macOS.
    /// 4. Starts the session and collects ~3 seconds of frames.
    /// 5. AFTER frames flow, reads back `device.activeFormat` dimensions — a reversion would
    ///    show here even if the lock block appeared to succeed.
    /// 6. Logs four signals with DIAGNOSTIC #113 [setActiveFormat] prefixes:
    ///    delivered buffer dims, actual fps, read-back activeFormat dims, delivered FourCC.
    /// 7. Asserts only run validity: `frameCount > 0`.
    @Test(
        "DIAG — 4K via setActiveFormat (issue #113)",
        .enabled(if: diag4K_brioGateEnabled())
    )
    func diag_4K_viaSetActiveFormat() async throws {
        let brio = try Self.findBrio()

        // Find the first 4K format that supports ≥30 fps. Prefer 420v subtype (420YpCbCr8Bi
        // PlanarVideoRange) to mirror the production output configuration.
        guard let fourKFormat = Self.pick4KFormat(from: brio) else {
            diag4KLogger.notice(
                "DIAGNOSTIC #113 [setActiveFormat] no 4K format in device.formats — not advertised by hardware"
            )
            Issue.record("Brio advertises no 3840×2160 format in device.formats on this system")
            return
        }

        let formatIndex = brio.formats.firstIndex(of: fourKFormat) ?? -1
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [setActiveFormat] selected format index=\(formatIndex, privacy: .public)"
        )
        let selDims = CMVideoFormatDescriptionGetDimensions(fourKFormat.formatDescription)
        let selW = selDims.width, selH = selDims.height
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [setActiveFormat] selectedDims=\(selW, privacy: .public)x\(selH, privacy: .public)"
        )

        // Log preset gate signal early (cheap — no session needed).
        let tempSession = AVCaptureSession()
        let canUsePreset = tempSession.canSetSessionPreset(.hd4K3840x2160)
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [setActiveFormat] canSetSessionPreset(.hd4K3840x2160)=\(canUsePreset, privacy: .public)"
        )

        // Build session.
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: brio)
        guard session.canAddInput(input) else {
            Issue.record("AVCaptureSession cannot add Brio input")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true

        let collector = Diag4KFrameCollector()
        let delegateQueue = DispatchQueue(label: "dev.androidbroadcast.Onset.diag4K.setActiveFormat")
        output.setSampleBufferDelegate(collector, queue: delegateQueue)

        guard session.canAddOutput(output) else {
            Issue.record("AVCaptureSession cannot add video output")
            return
        }
        session.addOutput(output)

        // Set activeFormat and pin fps under lockForConfiguration.
        try brio.lockForConfiguration()
        brio.activeFormat = fourKFormat
        let thirtyFpsTime = Self.thirtyFpsDuration(from: fourKFormat)
        brio.activeVideoMinFrameDuration = thirtyFpsTime
        brio.activeVideoMaxFrameDuration = thirtyFpsTime
        brio.unlockForConfiguration()

        session.startRunning()
        defer {
            session.stopRunning()
        }

        guard session.isRunning else {
            Issue.record("AVCaptureSession failed to start (isRunning == false after startRunning)")
            return
        }

        // Collect ~3 seconds of frames.
        try await Task.sleep(for: .seconds(3))

        // Read back activeFormat AFTER frames have flowed — reversion happens at session
        // start, not at the lockForConfiguration block.
        let readBackDims = CMVideoFormatDescriptionGetDimensions(brio.activeFormat.formatDescription)
        let snap = collector.snapshot

        // Delta stats and fps derived from PTS values (pure computation off the lock).
        let deltaStats = Diag4KDeltaStats(from: snap)

        // Wall-clock fps: frameCount / nominal collection window (warmup-inclusive).
        // Contrasts with ptsFps (first→last PTS span, warmup-exclusive) to expose UVC latency.
        let wallClockFps = Double(snap.frameCount) / 3.0

        // Log all diagnostic signals.
        let delW = snap.lastWidth, delH = snap.lastHeight
        let readW = readBackDims.width, readH = readBackDims.height
        let frameN = snap.frameCount
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [setActiveFormat] delivered=\(delW, privacy: .public)x\(delH, privacy: .public)"
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [setActiveFormat] ptsFps=\(deltaStats.ptsFps, privacy: .public) \
            wallClockFps=\(wallClockFps, privacy: .public) n=\(frameN, privacy: .public)
            """
        )
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [setActiveFormat] readBack=\(readW, privacy: .public)x\(readH, privacy: .public)"
        )
        diag4KLogger.notice("DIAGNOSTIC #113 [setActiveFormat] fourCC=\(snap.lastFourCC, privacy: .public)")
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [setActiveFormat] firstPTS=\(snap.firstTimestamp, privacy: .public) \
            lastPTS=\(snap.lastTimestamp, privacy: .public) ptsCount=\(snap.ptsValues.count, privacy: .public)
            """
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [setActiveFormat] deltaMs \
            mean=\(deltaStats.meanMs, privacy: .public) \
            min=\(deltaStats.minMs, privacy: .public) \
            max=\(deltaStats.maxMs, privacy: .public) \
            std=\(deltaStats.stdMs, privacy: .public)
            """
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [setActiveFormat] deltaHist \
            <14=\(deltaStats.histBelow14, privacy: .public) \
            14-20=\(deltaStats.hist14to20, privacy: .public) \
            20-40=\(deltaStats.hist20to40, privacy: .public) \
            40-60=\(deltaStats.hist40to60, privacy: .public) \
            >60=\(deltaStats.histAbove60, privacy: .public)
            """
        )

        // Assert only run validity — NOT that 4K was delivered.
        #expect(snap.frameCount > 0, "No frames were delivered during the 3s collection window")
    }

    // swiftlint:enable function_body_length

    // MARK: - Test 2 — sessionPreset path

    // swiftlint:disable function_body_length
    /// Probes 4K delivery via `AVCaptureSession.sessionPreset = .hd4K3840x2160`.
    ///
    /// Steps:
    /// 1. Builds a bare `AVCaptureSession` with a `AVCaptureVideoDataOutput` (420v pixel format).
    /// 2. Checks `session.canSetSessionPreset(.hd4K3840x2160)` — logs the result.
    ///    If `false`, records the finding via `Issue.record` and returns (valid diagnostic result).
    /// 3. Assigns `session.sessionPreset = .hd4K3840x2160`.
    /// 4. Starts the session and collects ~3 seconds of frames.
    /// 5. Reads back `device.activeFormat` dims after frames flow.
    /// 6. Logs four signals with DIAGNOSTIC #113 [preset] prefixes.
    /// 7. Asserts only run validity: `frameCount > 0`.
    @Test(
        "DIAG — 4K via sessionPreset (issue #113)",
        .enabled(if: diag4K_brioGateEnabled())
    )
    func diag_4K_viaSessionPreset() async throws {
        let brio = try Self.findBrio()

        // Build session.
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: brio)
        guard session.canAddInput(input) else {
            Issue.record("AVCaptureSession cannot add Brio input")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true

        let collector = Diag4KFrameCollector()
        let delegateQueue = DispatchQueue(label: "dev.androidbroadcast.Onset.diag4K.preset")
        output.setSampleBufferDelegate(collector, queue: delegateQueue)

        guard session.canAddOutput(output) else {
            Issue.record("AVCaptureSession cannot add video output")
            return
        }
        session.addOutput(output)

        // Gate on canSetSessionPreset — this is the key signal for the preset path.
        let canSetPreset = session.canSetSessionPreset(.hd4K3840x2160)
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [preset] canSetSessionPreset(.hd4K3840x2160)=\(canSetPreset, privacy: .public)"
        )

        if canSetPreset {
            session.sessionPreset = .hd4K3840x2160
        } else {
            Issue.record(
                """
                session.canSetSessionPreset(.hd4K3840x2160) == false — \
                4K preset is not available for the Brio on this system (valid diagnostic result)
                """
            )
            return
        }

        session.startRunning()
        defer {
            session.stopRunning()
        }

        guard session.isRunning else {
            Issue.record("AVCaptureSession failed to start (isRunning == false after startRunning)")
            return
        }

        // Collect ~3 seconds of frames.
        try await Task.sleep(for: .seconds(3))

        // Read back activeFormat dims after frames have flowed.
        let readBackDims = CMVideoFormatDescriptionGetDimensions(brio.activeFormat.formatDescription)
        let snap = collector.snapshot

        let elapsed = snap.lastTimestamp - snap.firstTimestamp
        let actualFps: Double = if snap.frameCount >= 2, elapsed > 0 {
            Double(snap.frameCount - 1) / elapsed
        } else {
            0
        }

        // Log all four diagnostic signals.
        let deliveredW = snap.lastWidth, deliveredH = snap.lastHeight
        let readW = readBackDims.width, readH = readBackDims.height
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [preset] delivered=\(deliveredW, privacy: .public)x\(deliveredH, privacy: .public)"
        )
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [preset] fps=\(actualFps, privacy: .public) n=\(snap.frameCount, privacy: .public)"
        )
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [preset] readBack=\(readW, privacy: .public)x\(readH, privacy: .public)"
        )
        diag4KLogger.notice("DIAGNOSTIC #113 [preset] fourCC=\(snap.lastFourCC, privacy: .public)")

        // Assert only run validity — NOT that 4K was delivered.
        #expect(snap.frameCount > 0, "No frames were delivered during the 3s collection window")
    }

    // swiftlint:enable function_body_length

    // MARK: - Test 3 — native 1080p60 sustained-fps probe

    // swiftlint:disable function_body_length
    /// Measures whether AVFoundation can sustain native 1080p (1920×1080) at 60 fps from the Brio.
    ///
    /// Steps:
    /// 1. Discovers the best 1920×1080 format in `device.formats` whose `videoSupportedFrameRateRanges`
    ///    includes a range with `maxFrameRate >= 60`. If none exists, records a finding and returns
    ///    (valid diagnostic result — the answer is unknown before we measure it).
    /// 2. Builds a bare `AVCaptureSession`, adds the Brio `AVCaptureDeviceInput`, and adds a
    ///    `AVCaptureVideoDataOutput` with 420v pixel format.
    /// 3. Under `lockForConfiguration()`, sets `activeFormat` to the selected 1080p60 format and pins
    ///    `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` to 60 fps (the only fps-pinning
    ///    mechanism on macOS — `autoVideoFrameRateEnabled` does not exist on this platform).
    /// 4. Starts the session and collects a 5-second window (longer than the 4K probe's 3 s — needed
    ///    to accumulate a stable 60 fps estimate after camera warmup).
    /// 5. After frames have flowed, reads back `device.activeFormat` dimensions to catch any silent
    ///    format reversion that happens at session start.
    /// 6. Logs all diagnostic signals with the `DIAGNOSTIC #113 [1080p60]` prefix:
    ///    `selectedDims`, `targetFps`, `delivered`, `sustainedFps`, `readBack`, `fourCC`, `frameCount`.
    ///    Sustained fps is derived from delivered frame PTS timestamps (not from wall-clock / nominal)
    ///    to exclude camera warmup latency before the first frame arrives.
    /// 7. Asserts only run validity: `frameCount > 0`. Fps is logged, never asserted.
    @Test(
        "1080p60 sustained-fps probe",
        .enabled(if: diag4K_brioGateEnabled())
    )
    func diag_1080p60_sustainedFps() async throws {
        let brio = try Self.findBrio()

        // Select the native 1080p60 format, bypassing all project cap logic.
        guard let format1080p60 = Self.pick1080p60Format(from: brio) else {
            diag4KLogger.notice(
                "DIAGNOSTIC #113 [1080p60] no 1920×1080 format with maxFrameRate>=60 in device.formats"
            )
            Issue.record("Brio advertises no 1920×1080 / ≥60 fps format in device.formats on this system")
            return
        }

        let selDims = CMVideoFormatDescriptionGetDimensions(format1080p60.formatDescription)
        let selW = selDims.width, selH = selDims.height
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [1080p60] selectedDims=\(selW, privacy: .public)x\(selH, privacy: .public)"
        )
        diag4KLogger.notice("DIAGNOSTIC #113 [1080p60] targetFps=60")

        // Build session.
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: brio)
        guard session.canAddInput(input) else {
            Issue.record("AVCaptureSession cannot add Brio input")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        // Keep alwaysDiscardsLateVideoFrames=true so we measure real-time deliverable rate,
        // not a backlogged catch-up burst.
        output.alwaysDiscardsLateVideoFrames = true

        let collector = Diag4KFrameCollector()
        let delegateQueue = DispatchQueue(label: "dev.androidbroadcast.Onset.diag4K.diag1080p60")
        output.setSampleBufferDelegate(collector, queue: delegateQueue)

        guard session.canAddOutput(output) else {
            Issue.record("AVCaptureSession cannot add video output")
            return
        }
        session.addOutput(output)

        // Pin activeFormat and fps under lockForConfiguration.
        // Derive the lock duration from the format's own AVFrameRateRange rather than
        // constructing CMTimeMake(1, 60) by hand. The Brio's 1080p60 format reports its
        // top rate as ~59.94 (NTSC), so a hand-built 1/60 falls outside
        // videoSupportedFrameRateRanges and AVCaptureDevice throws NSInvalidArgumentException.
        guard let sixtyFpsTime = Self.maxFpsDuration(from: format1080p60) else {
            diag4KLogger.notice(
                "DIAGNOSTIC #113 [1080p60] no fps range with maxFrameRate>=60 in selected format — cannot pin"
            )
            Issue.record("Selected 1080p60 format has no AVFrameRateRange with maxFrameRate>=60")
            return
        }
        try brio.lockForConfiguration()
        brio.activeFormat = format1080p60
        brio.activeVideoMinFrameDuration = sixtyFpsTime
        brio.activeVideoMaxFrameDuration = sixtyFpsTime
        brio.unlockForConfiguration()

        session.startRunning()
        defer {
            session.stopRunning()
        }

        guard session.isRunning else {
            Issue.record("AVCaptureSession failed to start (isRunning == false after startRunning)")
            return
        }

        // Collect ~5 seconds of frames — longer than the 4K probe (3 s) to accumulate a stable
        // sustained-fps estimate at 60 fps after the camera warmup period.
        try await Task.sleep(for: .seconds(5))

        // Read back activeFormat AFTER frames have flowed — a silent reversion would show here.
        let readBackDims = CMVideoFormatDescriptionGetDimensions(brio.activeFormat.formatDescription)
        let snap = collector.snapshot

        // Delta stats and fps derived from PTS values (pure computation off the lock).
        let deltaStats = Diag4KDeltaStats(from: snap)

        // Wall-clock fps: frameCount / nominal collection window (warmup-inclusive).
        // sustainedFps (= ptsFps) excludes warmup; wallClockFps includes it.
        // The gap between the two reveals UVC startup latency contribution.
        let wallClockFps = Double(snap.frameCount) / 5.0

        // Sustained fps is PTS-span-based (warmup-exclusive) — kept for backward compat.
        let sustainedFps = deltaStats.ptsFps

        // Log all diagnostic signals.
        let delW = snap.lastWidth, delH = snap.lastHeight
        let readW = readBackDims.width, readH = readBackDims.height
        let frameN = snap.frameCount
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [1080p60] delivered=\(delW, privacy: .public)x\(delH, privacy: .public)"
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [1080p60] ptsFps=\(sustainedFps, privacy: .public) \
            wallClockFps=\(wallClockFps, privacy: .public)
            """
        )
        // Keep the pre-existing sustainedFps= line so external log parsers that grep for it still match.
        diag4KLogger.notice("DIAGNOSTIC #113 [1080p60] sustainedFps=\(sustainedFps, privacy: .public)")
        diag4KLogger.notice(
            "DIAGNOSTIC #113 [1080p60] readBack=\(readW, privacy: .public)x\(readH, privacy: .public)"
        )
        diag4KLogger.notice("DIAGNOSTIC #113 [1080p60] fourCC=\(snap.lastFourCC, privacy: .public)")
        diag4KLogger.notice("DIAGNOSTIC #113 [1080p60] frameCount=\(frameN, privacy: .public)")
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [1080p60] firstPTS=\(snap.firstTimestamp, privacy: .public) \
            lastPTS=\(snap.lastTimestamp, privacy: .public) ptsCount=\(snap.ptsValues.count, privacy: .public)
            """
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [1080p60] deltaMs \
            mean=\(deltaStats.meanMs, privacy: .public) \
            min=\(deltaStats.minMs, privacy: .public) \
            max=\(deltaStats.maxMs, privacy: .public) \
            std=\(deltaStats.stdMs, privacy: .public)
            """
        )
        diag4KLogger.notice(
            """
            DIAGNOSTIC #113 [1080p60] deltaHist \
            <14=\(deltaStats.histBelow14, privacy: .public) \
            14-20=\(deltaStats.hist14to20, privacy: .public) \
            20-40=\(deltaStats.hist20to40, privacy: .public) \
            40-60=\(deltaStats.hist40to60, privacy: .public) \
            >60=\(deltaStats.histAbove60, privacy: .public)
            """
        )

        // Assert only run validity — fps is a measurement, not an assertion.
        #expect(snap.frameCount > 0, "No frames delivered during the 5 s collection window")
    }

    // swiftlint:enable function_body_length

    // MARK: - Shared helpers

    /// Locates the connected Brio device.
    ///
    /// - Throws: A descriptive error when no Brio is found. `diag4K_brioGateEnabled()` should
    ///   have skipped this test before `findBrio()` is called, so a throw here signals a
    ///   transient disconnect between the gate evaluation and the test body.
    private static func findBrio() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceDiscovery.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        guard let brio = discovery.devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("Brio") })
        else {
            throw Diag4KSetupError.noBrio
        }
        return brio
    }

    /// Picks the best 4K (3840×2160) format from `device.formats` that supports ≥30 fps.
    ///
    /// Selection criteria (in order):
    /// 1. Width == 3840 and height == 2160.
    /// 2. At least one `videoSupportedFrameRateRange` with `maxFrameRate >= 30`.
    /// 3. Prefer formats whose media subtype is `420v` (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ///    to mirror the production pixel-format configuration.
    ///
    /// - Returns: The selected `AVCaptureDevice.Format`, or `nil` if no 4K format is found.
    private static func pick4KFormat(from device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard dims.width == 3840, dims.height == 2160 else { return false }
            return fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer 420v subtype; fall back to whatever is available.
        let preferred420v = candidates.first { fmt in
            CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        return preferred420v ?? candidates.first
    }

    /// Returns the `CMTime` for a 30 fps frame duration compatible with `fourKFormat`.
    ///
    /// Uses the `minFrameDuration` from the first fps range whose `maxFrameRate >= 30`, which
    /// gives the rational form stored in the hardware (e.g. 1001/30000 for 29.97).
    /// Falls back to `CMTimeMake(value:timescale:)` with 1/30 if no matching range is found.
    private static func thirtyFpsDuration(from format: AVCaptureDevice.Format) -> CMTime {
        let matchingRange = format.videoSupportedFrameRateRanges
            .first { $0.maxFrameRate >= 30 }
        return matchingRange?.minFrameDuration ?? CMTimeMake(value: 1, timescale: 30)
    }

    /// Returns the `CMTime` for the highest achievable frame rate in `format`, derived from the
    /// format's own `videoSupportedFrameRateRanges`.
    ///
    /// Picks the range with the greatest `maxFrameRate` among those whose `maxFrameRate >= 60` and
    /// returns its `minFrameDuration` — the shortest duration the device will accept for that range.
    /// Using the range's own `minFrameDuration` rather than a hand-built `CMTimeMake(1, 60)` avoids
    /// `NSInvalidArgumentException` on cameras that report NTSC top rates (~59.94) instead of exactly 60.
    ///
    /// - Parameter format: The `AVCaptureDevice.Format` to inspect.
    /// - Returns: The `minFrameDuration` of the qualifying range, or `nil` if no range with
    ///   `maxFrameRate >= 60` exists in `format`.
    private static func maxFpsDuration(from format: AVCaptureDevice.Format) -> CMTime? {
        format.videoSupportedFrameRateRanges
            .filter { $0.maxFrameRate >= 60 }
            .max { $0.maxFrameRate < $1.maxFrameRate }?
            .minFrameDuration
    }

    /// Picks the best native 1080p (1920×1080) format from `device.formats` that supports ≥60 fps.
    ///
    /// Selection criteria (in order):
    /// 1. Width == 1920 and height == 1080.
    /// 2. At least one `videoSupportedFrameRateRange` with `maxFrameRate >= 60`.
    /// 3. Prefer formats whose media subtype is `420v` (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ///    to mirror the production output configuration.
    ///
    /// - Returns: The selected `AVCaptureDevice.Format`, or `nil` if no qualifying format is found.
    private static func pick1080p60Format(from device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard dims.width == 1920, dims.height == 1080 else { return false }
            return fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer 420v subtype; fall back to whatever is available.
        let preferred420v = candidates.first { fmt in
            CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        return preferred420v ?? candidates.first
    }
}

// swiftlint:enable type_body_length

// MARK: - Setup errors

/// Errors thrown by the diagnostic test setup helpers.
private enum Diag4KSetupError: Error {
    /// No connected camera whose `localizedName` contains "Brio" was found.
    ///
    /// `diag4K_brioGateEnabled()` should prevent this during normal test execution;
    /// a throw here indicates a transient disconnect between gate evaluation and test body.
    case noBrio
}
