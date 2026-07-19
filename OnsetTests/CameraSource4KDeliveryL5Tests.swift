import AVFoundation
import CoreMedia
import CoreVideo
@testable import Onset
import os
import Testing

// L5 4K-delivery verification (issue #265, plan camera-4k-lock-lifecycle T-8).
//
// L2 coverage gap (explicit): the imperative lock-ownership logic in buildAndStartSession —
// the single `locked` flag, ownership hand-off to teardown, and prevention of double-unlock /
// lock leak — is verified by code review plus this L5 test, but is NOT covered by an L2 unit
// test. The reason: that logic is tightly bound to a live AVCaptureDevice
// (lockForConfiguration on real hardware), and introducing a mock seam purely to unit-test an
// internal lock flag would be disproportionate over-engineering relative to the benefit.
//
// This file is the ONLY gate that closes the "4K is really delivered" contract — neither L2
// nor CI can close it (no camera on the runners). It drives a real camera (MX Brio on a DIRECT
// USB3 connection — a hub silently caps to 1080p) through the PRODUCTION path:
//   pickBestFormat(allowAboveFullHD: true) → CameraSource(role: .record) → start → frames
// and asserts the delivered CVPixelBuffer is 3840×2160. The historical bug (#265) was that a
// selected 4K activeFormat silently reverted to 1080p on delivery; this is why there are TWO
// asserts — the selected format AND the delivered buffers — so a selector regression and a
// delivery regression remain distinguishable.
//
// The bitrate/file-size sanity and combined screen+camera checks listed in tasks.md T-8 are the
// operator-run portion (they need RecordingSession/FileWriter) and are deliberately NOT in this
// file: this suite is CameraSource-only.
//
// no_magic_numbers is disabled file-wide: L5 dimensions (3840/2160), frame counts and timeouts
// are inline test fixtures, not production constants.
// swiftlint:disable no_magic_numbers

// MARK: - L5 opt-in condition

/// Returns `true` when the 4K-delivery L5 test should run. Both must hold:
/// 1. `ONSET_RUN_L5_CAPTURE=1` is set (explicit opt-in).
/// 2. TCC authorization is granted for both camera and microphone.
///
/// Used as `.enabled(if:)` so a non-opted-in run reports a genuine SKIP, never a false PASS.
/// (Mirrors `l5CaptureEnabled` in `CameraSourceLogicTests.swift` — `private` there is file-scoped,
/// so this is an intentional self-contained copy, not a shared symbol.)
private func fourKL5Enabled() -> Bool {
    guard ProcessInfo.processInfo.environment["ONSET_RUN_L5_CAPTURE"] == "1" else {
        return false
    }
    let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    return isCaptureAuthorized(video: videoStatus, audio: audioStatus)
}

// MARK: - L5 4K-delivery suite

/// `.serialized` because this is a SECOND L5 capture suite: `-testPlan Onset-L5` runs it alongside
/// `CameraSourceLiveTests`, and two suites grabbing the same camera concurrently hang the test host.
/// `.serialized` orders the tests within this suite; to keep the two L5 capture suites from
/// fighting over the camera, run them one at a time via `-only-testing` if the runner parallelizes
/// across suites. Pin the reference camera with `ONSET_L5_CAMERA_NAME=MX Brio`.
@Suite("CameraSource — L5 4K delivery", .serialized, .timeLimit(.minutes(2)))
struct CameraSource4KDeliveryL5Tests {
    @Test(
        "record role with allowAboveFullHD selects 4K and delivers 3840×2160 buffers",
        .enabled(if: fourKL5Enabled())
    )
    func recordRole_selects4K_andDelivers4KBuffers() async throws {
        // Resolve the camera + 4K format up front. A missing camera/mic is a genuine SKIP
        // (the env+TCC gate already passed), so we early-return with a loud log, not a failure.
        guard let setup = try makeFourKCaptureSource() else { return }

        // Assert #1 (selector): the production path picked 4K. Separates a selector regression
        // from a delivery regression — if this fails, the cap-lift (T-4) did not yield 4K.
        // Comment(rawValue:) is required: Swift Testing auto-converts a string LITERAL to Comment?,
        // but an interpolated/computed String must be wrapped explicitly.
        let selectorComment = Comment(
            rawValue: "pickBestFormat(allowAboveFullHD: true) must select 4K — got "
                + "\(setup.format.pixelWidth)×\(setup.format.pixelHeight). "
                + "Reference camera must advertise 3840×2160 16:9 on a DIRECT USB3 link."
        )
        try #require(
            setup.format.pixelWidth == 3840 && setup.format.pixelHeight == 2160,
            selectorComment
        )

        try await setup.source.start(anchoredTo: setup.anchor)

        // Drain `drops` concurrently with frame collection: `drops` only finishes when stop()
        // calls dropsContinuation.finish(), so it MUST be awaited after stop(), never before.
        async let collectedDrops: [DropEvent] = collectDrops(from: setup.source.drops)

        let frames: [VideoFrame]
        do {
            frames = try await collectVideoFrames(from: setup.source, targetCount: 90)
        } catch {
            await setup.source.stop()
            _ = await collectedDrops
            Issue.record("L5 4K capture did not deliver enough frames within 20s: \(error)")
            return
        }

        await setup.source.stop()
        let drops = await collectedDrops

        // Assert #2 (delivery): the modal delivered resolution is 3840×2160. Use the mode over
        // all-but-the-first-frames so a brief warm-up frame can't skew the verdict (#265: the
        // selected 4K format silently reverted to 1080p on delivery before this fix).
        let stableFrames = frames.count > 2 ? Array(frames.dropFirst(2)) : frames
        let (modalWidth, modalHeight) = modalDimensions(of: stableFrames)
        let deliveryComment = Comment(
            rawValue: "Delivered buffers must be 3840×2160 (no revert to 1080p) — modal delivery was "
                + "\(modalWidth)×\(modalHeight) over \(stableFrames.count) stable frames."
        )
        #expect(modalWidth == 3840 && modalHeight == 2160, deliveryComment)

        // The pixel format must be 420v (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) —
        // videoSettings requests it explicitly; a nil request would yield 2vuy, unusable for HEVC.
        for frame in stableFrames {
            #expect(
                CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
        }

        // SOFT diagnostics — logged, NOT asserted. Brio tops out at ~24–25 fps; failing on <30
        // would be a false negative (hardware ceiling, not a regression — see project memory).
        logSoftFps(frames: stableFrames)
        logDrops(drops)
    }
}

// MARK: - L5 setup

private struct FourKCaptureSetup {
    let source: CameraSource
    let format: CameraFormat
    let anchor: HostTimeAnchor
}

private let fourKL5Logger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CameraSource4KDeliveryL5Tests"
)

/// 4K 16:9 dimensions the reference camera must advertise for this L5 test to run.
private let fourKWidth: Int32 = 3840
private let fourKHeight: Int32 = 2160

/// Builds a `.record` `CameraSource` via the production path, requesting 4K through
/// `pickBestFormat(allowAboveFullHD: true)` (the record-only opt-in from T-4).
///
/// Camera selection is CAPABILITY-based, NOT env-based: it picks the connected camera whose
/// advertised `formats` actually include a 3840×2160 16:9 format. This is the correct precondition
/// for a "4K delivery" L5 test — `DeviceDiscovery.cameras().first` is unreliable (OBS Virtual /
/// FaceTime / iPhone Continuity are all ≤1080p), and `ONSET_L5_CAMERA_NAME` does NOT reach the
/// test host: `testmanagerd` launches the process with a controlled environment, so only env vars
/// declared in `Onset-L5.xctestplan` (like `ONSET_RUN_L5_CAPTURE`) are visible — an arbitrary shell
/// var is not inherited. `ONSET_L5_CAMERA_NAME` is kept ONLY as an optional override for the case
/// where it is wired into the test plan; when absent (the normal case) the 4K-capable auto-pick runs.
///
/// Returns `nil` (a genuine SKIP, not a failure) when no 4K-capable camera or no microphone is
/// present — the task is explicit that missing hardware skips rather than fails.
private func makeFourKCaptureSource() throws -> FourKCaptureSetup? {
    let cameras = DeviceDiscovery.cameras(cameraAuthorized: true)

    guard let camera = pickFourKCapableCamera(from: cameras) else {
        fourKL5Logger.notice(
            "L5_4K_SKIP reason=no_4k_capable_camera — connect MX Brio on direct USB3 (a hub caps to 1080p)"
        )
        return nil
    }

    guard let avMic = AVCaptureDevice.default(for: .audio) else {
        fourKL5Logger.notice("L5_4K_SKIP reason=no_microphone")
        return nil
    }
    let micDevice = MicrophoneDevice(uniqueID: avMic.uniqueID)

    let config = RecordingConfiguration.mvpDefault
    // allowAboveFullHD: true — the record-only opt-in that lifts the 1080p cap so 4K is selected.
    let selectedFormat = try CameraFormatSelector.pickBestFormat(
        from: camera.formats,
        minFps: Double(config.minCameraFps),
        allowAboveFullHD: true
    )

    let source = CameraSource(
        cameraDevice: camera,
        format: selectedFormat,
        micDevice: micDevice,
        config: config,
        role: .record
    )
    return FourKCaptureSetup(source: source, format: selectedFormat, anchor: HostTimeAnchor.now())
}

/// True when `format` is exactly 3840×2160 16:9 (the 4K precondition for this L5 test).
private func isFourKSixteenByNine(_ format: CameraFormat) -> Bool {
    format.pixelWidth == fourKWidth && format.pixelHeight == fourKHeight
}

/// Picks the connected camera that advertises a 3840×2160 16:9 format.
///
/// When `ONSET_L5_CAMERA_NAME` IS set AND reaches the host, the camera matching that name is
/// preferred (and still required to advertise 4K). Otherwise the first 4K-capable camera is used.
/// Logs the chosen camera's max-format dimensions (NOT its name — PII) to aid future diagnosis.
private func pickFourKCapableCamera(from cameras: [CameraDevice]) -> CameraDevice? {
    let fourKCapable = cameras.filter { camera in
        camera.formats.contains(where: isFourKSixteenByNine)
    }

    // Optional override: prefer a name-matched 4K-capable camera when the env var is present.
    let nameMatched = fourKCameraName().flatMap { nameMatchedCamera(from: fourKCapable, nameFilter: $0) }
    if let nameMatched {
        fourKL5Logger.notice("L5_4K_CAMERA_PICK name_matched=true")
        logMaxFormat(of: nameMatched)
        return nameMatched
    }

    guard let chosen = fourKCapable.first else { return nil }
    fourKL5Logger.notice("L5_4K_CAMERA_PICK name_matched=false picked=auto_4k_capable")
    logMaxFormat(of: chosen)
    return chosen
}

/// Logs the chosen camera's largest advertised format dimensions. NON-PII: dimensions only, no name.
private func logMaxFormat(of camera: CameraDevice) {
    let maxFormat = camera.formats.max { lhs, rhs in
        Int(lhs.pixelWidth) * Int(lhs.pixelHeight) < Int(rhs.pixelWidth) * Int(rhs.pixelHeight)
    }
    let width = maxFormat?.pixelWidth ?? 0
    let height = maxFormat?.pixelHeight ?? 0
    fourKL5Logger.notice(
        "L5_4K_CAMERA_MAXFORMAT width=\(width, privacy: .public) height=\(height, privacy: .public)"
    )
}

/// Reads `ONSET_L5_CAMERA_NAME` (case-insensitive substring filter). Unset/empty → nil (auto-pick).
private func fourKCameraName() -> String? {
    guard let raw = ProcessInfo.processInfo.environment["ONSET_L5_CAMERA_NAME"],
          !raw.isEmpty
    else { return nil }
    return raw
}

/// Returns the camera from `cameras` whose `AVCaptureDevice.localizedName` contains `nameFilter`.
/// The name is used transiently for matching only and is never logged (PII — `CameraDevice` stores
/// only `uniqueID`/`formats`). Returns `nil` when no name matches.
private func nameMatchedCamera(from cameras: [CameraDevice], nameFilter: String) -> CameraDevice? {
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: DeviceDiscovery.cameraDeviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    let matchedID = discoverySession.devices
        .first { $0.localizedName.localizedCaseInsensitiveContains(nameFilter) }
        .map(\.uniqueID)

    guard let matchedID else { return nil }
    return cameras.first { $0.uniqueID == matchedID }
}

// MARK: - L5 collection helpers

private struct L5FourKTimeoutError: Error {}

/// Collects `targetCount` frames, racing a 20s deadline. On timeout the collector task is
/// cancelled; AsyncStream iteration returns nil on cancellation, so the loop exits without hanging.
nonisolated private func collectVideoFrames(
    from source: CameraSource,
    targetCount: Int
) async throws
-> [VideoFrame] {
    let videoStream = source.frames
    return try await withThrowingTaskGroup(of: [VideoFrame].self) { group in
        group.addTask {
            var collected: [VideoFrame] = []
            for await frame in videoStream {
                collected.append(frame)
                if collected.count >= targetCount {
                    break
                }
            }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: .seconds(20))
            throw L5FourKTimeoutError()
        }
        guard let result = try await group.next() else { throw L5FourKTimeoutError() }
        group.cancelAll()
        return result
    }
}

/// Drains the `drops` stream until it finishes. The caller MUST start this BEFORE `stop()` and
/// `await` it AFTER `stop()` — the stream only finishes when stop() calls `dropsContinuation.finish()`.
nonisolated private func collectDrops(from stream: AsyncStream<DropEvent>) async -> [DropEvent] {
    var collected: [DropEvent] = []
    for await drop in stream {
        collected.append(drop)
    }
    return collected
}

// MARK: - L5 analysis helpers

/// The most frequent (width, height) pair across `frames`. Empty input → (0, 0).
nonisolated private func modalDimensions(of frames: [VideoFrame]) -> (width: Int, height: Int) {
    var histogram: [String: (dims: (Int, Int), count: Int)] = [:]
    for frame in frames {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let key = "\(width)x\(height)"
        let previous = histogram[key]?.count ?? 0
        histogram[key] = (dims: (width, height), count: previous + 1)
    }
    guard let winner = histogram.values.max(by: { $0.count < $1.count }) else {
        return (width: 0, height: 0)
    }
    return (width: winner.dims.0, height: winner.dims.1)
}

/// Logs the measured fps from frame PTS deltas. SOFT only — Brio's hardware ceiling is ~24–25 fps,
/// so a value below 30 is expected and must NOT fail the test (project memory: camera-capture-fps-macos).
nonisolated private func logSoftFps(frames: [VideoFrame]) {
    guard frames.count >= 2 else {
        fourKL5Logger.notice("L5_4K_FPS frames=\(frames.count, privacy: .public) measured=insufficient")
        return
    }
    let firstSec = CMTimeGetSeconds(frames[0].ptsHostTime)
    let lastSec = CMTimeGetSeconds(frames[frames.count - 1].ptsHostTime)
    let span = lastSec - firstSec
    guard span > 0 else {
        fourKL5Logger.notice("L5_4K_FPS frames=\(frames.count, privacy: .public) measured=zero_span")
        return
    }
    let fps = Double(frames.count - 1) / span
    // SOFT diagnostic (see doc-comment): ~24-25 fps is the Brio ceiling, NOT a failure if <30.
    fourKL5Logger.notice(
        "L5_4K_FPS frames=\(frames.count, privacy: .public) measured_fps=\(fps, privacy: .public)"
    )
}

/// Logs the cumulative capture-drop count over the run. SOFT only — the acceptability threshold is
/// the operator's call (tasks.md T-8); this is a diagnostic, not an assertion.
nonisolated private func logDrops(_ drops: [DropEvent]) {
    let captureDrops = drops
        .filter { $0.reason == .captureDrop }
        .reduce(0) { $0 + $1.count }
    let totalDrops = drops.reduce(0) { $0 + $1.count }
    fourKL5Logger.notice(
        "L5_4K_DROPS capture=\(captureDrops, privacy: .public) total=\(totalDrops, privacy: .public)"
    )
}

// swiftlint:enable no_magic_numbers
