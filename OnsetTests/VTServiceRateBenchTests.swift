import CoreMedia
import CoreVideo
import Foundation
@testable import Onset
import os
import OSLog
import Testing
import VideoToolbox

// file_length is disabled: bench harness, arm configuration, result types, and helpers are a
// single cohesive concern; splitting would scatter shared pixel-buffer fixtures.
// function_body_length is disabled: runArm is an intentionally dense measurement harness —
// it owns the full lifecycle (alloc → feed → drain → report) and splitting it would obscure
// the measurement boundary and introduce error-prone state hand-off.
// swiftlint:disable file_length
// swiftlint:disable function_body_length

// MARK: - L5 gate

/// Returns `true` when the bench should run.
///
/// Gated on `ONSET_RUN_L5_BENCH=1` (explicit opt-in). Reports as a genuine SKIP on
/// non-opted-in runs so the suite never appears as a false PASS in CI.
private func l5BenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_RUN_L5_BENCH"] == "1"
}

/// Returns `true` when the named arm is selected for this run.
///
/// When `ONSET_BENCH_ARMS` is unset or empty, all arms are selected (default behavior).
/// When set to a comma-separated list of arm names (e.g. `gateWideStatic,longrunMotion180`),
/// only the arms whose names appear in that list are selected; others report as genuine SKIPs
/// via `.enabled(if:)` — never as false PASSes.
///
/// Usage at call site: `.enabled(if: l5BenchEnabled() && armSelected("armName"))`
private func armSelected(_ name: String) -> Bool {
    let env = ProcessInfo.processInfo.environment["ONSET_BENCH_ARMS"] ?? ""
    guard !env.isEmpty else { return true }
    return env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(name)
}

// MARK: - Bench constants

private let benchFps = 60
private let benchWidth: Int32 = 3840
private let benchHeight: Int32 = 2160
private let benchTotalFrames = 1200 // 20 s × 60 fps
private let benchWarmupFrames = 120 // first 2 s excluded from summary metrics
private let benchLongrunFrames = 10800 // 180 s × 60 fps (arm 12)
private let benchNoiseBufferCount = 16 // motion arm: rotate through this many noise bufs
private let benchSamplerIntervalMs: UInt64 = 50 // pendingFrameCount poll cadence
/// Attoseconds per millisecond (10^15). Used to convert `Duration.components.attoseconds`
/// to milliseconds without importing Foundation's `TimeInterval` arithmetic.
private let benchAttoPerMs: Int64 = 1_000_000_000_000_000
private let benchOutputDir = "/tmp/onset-bench"

// MARK: - Pixel buffer helpers

/// Allocates a single IOSurface-backed 420v pixel buffer filled with random luma/chroma noise.
///
/// The IOSurface backing is required for VideoToolbox HW encode (VT reads via IOSurface handle;
/// a plain CVPixelBuffer without IOSurface is rejected by the HW encode session).
/// Allocates an empty (uninitialized) pixel buffer with the standard bench format and IOSurface backing.
///
/// The returned buffer's plane bytes are uninitialized — callers that need known content
/// must fill the planes themselves (noise fill or `copyPlanes`).
private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        preconditionFailure("pixel buffer alloc failed: \(status)")
    }
    return buffer
}

private func makeNoisyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let buffer = makePixelBuffer(width: width, height: height)

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    // Fill luma plane (0) and chroma plane (1) with random bytes.
    // arc4random_buf works on the raw UnsafeMutableRawPointer — no assumingMemoryBound needed.
    // This produces genuine inter-frame motion (different noise seeds per buffer) so the
    // encoder's motion-estimation path is exercised, not optimised away as a still scene.
    for planeIndex in 0..<CVPixelBufferGetPlaneCount(buffer) {
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex) {
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
            arc4random_buf(base, bytesPerRow * planeHeight)
        }
    }

    return buffer
}

/// Copies the luma and chroma planes from `src` into `dst` pixel-by-pixel.
///
/// Both buffers must share the same dimensions and pixel format. Used to build pools of
/// identical-content buffers for the `staticRotateN` arms — we want distinct `CVPixelBuffer`
/// objects (so VT sees different memory) but the same encoded content (to isolate the
/// same-buffer identity effect from the motion-estimation effect).
private func copyPlanes(src: CVPixelBuffer, dst: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
        CVPixelBufferUnlockBaseAddress(dst, [])
    }
    for planeIndex in 0..<CVPixelBufferGetPlaneCount(src) {
        guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, planeIndex) else { continue }
        guard let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, planeIndex) else { continue }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(src, planeIndex)
        let planeHeight = CVPixelBufferGetHeightOfPlane(src, planeIndex)
        memcpy(dstBase, srcBase, bytesPerRow * planeHeight)
    }
}

// MARK: - CapturingSessionFactory

/// A `SessionFactory` wrapper that captures the `CompressionSession` into a thread-safe box
/// immediately after the real factory creates it.
///
/// This gives the test side access to the live session for two purposes:
///   1. The pending-frame sampler reads `session.pendingFrameCount()` at 50 ms cadence.
///   2. `expectedFpsStatic` sets `kVTCompressionPropertyKey_ExpectedFrameRate` after start.
///
/// Concurrency contract:
///   - `store(_:)` is called exactly once, synchronously, from within `VideoEncoder.start()`
///     (on the VideoEncoder actor). `start()` completes before any sampler task or post-start
///     property call reads the box — Swift's structured-concurrency ordering guarantees the
///     write happens-before any read.
///   - `nonisolated(unsafe)` suppresses the strict-concurrency ownership check. The single-write
///     / happens-before guarantee makes this sound: the box is not `Sendable` by accident —
///     it is `@unchecked Sendable` with an explicit documented protocol.
private final class SessionBox: @unchecked Sendable {
    /// The captured session, set once by `store(_:)` before any `peek()` call.
    ///
    /// `nonisolated(unsafe)`: `any CompressionSession` is not `Sendable`, so Swift 6 strict
    /// concurrency would reject storing it in a cross-isolation field. The happens-before
    /// contract above (store completes inside start(); readers start after start() returns)
    /// ensures this is sound without a runtime lock.
    nonisolated(unsafe) private var session: (any CompressionSession)?

    /// Called once by the capturing factory closure to store the created session.
    func store(_ session: any CompressionSession) {
        precondition(self.session == nil, "SessionBox.store() called twice")
        self.session = session
    }

    /// Returns the session if the factory has already run; `nil` if called before start.
    func peek() -> (any CompressionSession)? {
        self.session
    }
}

// MARK: - BenchArm

/// Configuration for one measurement arm.
///
/// Separating arm identity from the per-arm parameters keeps the runner signature stable
/// as new arms are added.
private struct BenchArm {
    /// Stable file-system-safe name used for the JSON output path and log prefix.
    let name: String

    /// `allowFrameReordering` override; `nil` delegates to the production config value.
    let allowFrameReordering: Bool?

    /// VT backpressure gate — maximum in-flight frames before a new ingest is dropped.
    let maxPendingFrames: Int

    /// Pool configuration: how many distinct pixel buffers to rotate through.
    ///
    /// - `motion`: 16 distinct noise buffers (genuine inter-frame motion).
    /// - `static`: 1 noise buffer (same memory every frame — the collapsing case).
    /// - `rotate(n)`: n distinct buffers with IDENTICAL content (discriminates same-buffer
    ///   identity vs. content). The buffers are copies of a single noise seed so the encoder
    ///   sees different memory addresses but an identical encoded scene.
    /// - `noise(n)`: n distinct noise-filled buffers — genuine motion, explicit pool size.
    let poolMode: PoolMode

    /// Whether to set `kVTCompressionPropertyKey_ExpectedFrameRate` on the live VT session
    /// after `encoder.start()` returns. `nil` = do not set (default production behavior).
    let expectedFrameRate: Int?

    /// When non-nil, sets `kVTCompressionPropertyKey_MaxFrameDelayCount` on the live VT session
    /// immediately after `encoder.start()` (before the first frame is fed — required ordering).
    ///
    /// The `OSStatus` returned by `setProperty` is captured in `BenchResult.maxFrameDelayCountStatus`
    /// regardless of success: a non-noErr value (e.g. kVTPropertyNotSupportedErr) itself constitutes
    /// a finding — it indicates the HW encoder does not honour this property.
    let maxFrameDelayCount: Int?

    /// Creates an arm configuration. Fields with defaults reflect the standard production
    /// settings; spell out only the fields that deviate from those defaults.
    init(
        name: String,
        poolMode: PoolMode,
        allowFrameReordering: Bool? = nil,
        maxPendingFrames: Int = 4,
        expectedFrameRate: Int? = nil,
        maxFrameDelayCount: Int? = nil
    ) {
        precondition(!name.isEmpty, "BenchArm.name must not be empty")
        precondition(maxPendingFrames > 0, "BenchArm.maxPendingFrames must be > 0")
        self.name = name
        self.poolMode = poolMode
        self.allowFrameReordering = allowFrameReordering
        self.maxPendingFrames = maxPendingFrames
        self.expectedFrameRate = expectedFrameRate
        self.maxFrameDelayCount = maxFrameDelayCount
    }

    enum PoolMode {
        /// `benchNoiseBufferCount` (16) distinct noise-filled buffers — genuine motion.
        case motion
        /// 1 noise buffer repeated every frame — single-buffer static.
        case `static`
        /// N identical-content (copied) buffers cycled A,B,C,… .
        case rotate(_ count: Int)
        /// N distinct noise-filled buffers — genuine motion with explicit pool size.
        case noise(_ count: Int)
    }
}

// MARK: - BenchResult

/// Per-arm measurement result serialised to JSON.
private struct BenchResult: Codable {
    /// Arm identifier matching `BenchArm.name`.
    let armName: String

    /// Total frames submitted to the encoder (including warmup).
    let fedFrames: Int

    /// Frames submitted AFTER the warmup period (steady-state window).
    let steadyFrames: Int

    /// Total encoded outputs received across the full run (warmup + steady).
    let totalOutputs: Int

    /// Encoded outputs received during the steady-state window only.
    let steadyOutputs: Int

    /// Encoder-backpressure drops (gate drops) accumulated across the full run.
    let gateDropsTotal: Int

    /// Mean outputs per second during the steady-state window.
    let steadyMeanOutputsPerSec: Double

    /// Whether the session used the hardware encoder (queried after start, before stop).
    let usedHardwareEncoder: Bool

    /// Frames fed but not accounted for by outputs or gate drops.
    ///
    /// `unaccountedFrames = fedFrames − totalOutputs − gateDropsTotal`.
    /// Non-zero values indicate CFR hold-repeats, VT-internal drops (callback `.frameDropped`
    /// or status ≠ noErr), or frames still in flight when `stop()` drained — all sources
    /// other than the backpressure gate. Combine with `callbackFrameDropped`/`callbackFailed`
    /// to discriminate.
    let unaccountedFrames: Int

    /// VT output-callback frames with `infoFlags.contains(.frameDropped)` set.
    ///
    /// Queried from `OSLogStore(scope: .currentProcessIdentifier)` after the arm completes.
    /// `nil` when the log store query fails or is unavailable.
    let callbackFrameDropped: Int?

    /// VT output-callback frames where `status ≠ noErr`.
    ///
    /// Queried from `OSLogStore(scope: .currentProcessIdentifier)` after the arm completes.
    /// `nil` when the log store query fails or is unavailable.
    let callbackFailed: Int?

    /// Histogram of `pendingFrameCount()` depths sampled at ~50 ms cadence over the full run.
    ///
    /// Keys are string representations of depth values (JSON requires string keys).
    /// Values are the number of samples at that depth.
    /// Empty when fewer than 2 samples were collected (arm too short, or sampler not started).
    let pendingHistogram: [String: Int]

    /// Chronological sequence of `pendingFrameCount()` samples collected during the run.
    ///
    /// Each entry is a `(elapsedMs, depth)` pair where `elapsedMs` is milliseconds since
    /// `encoder.start()` completed. Useful for visualising oscillation or ramp patterns.
    let pendingTimeline: [[Int]]

    /// Most frequently observed `pendingFrameCount()` depth across all samples.
    ///
    /// `nil` when the histogram is empty (no samples collected).
    let modalPendingDepth: Int?

    /// Per-second output count, indexed by integer second since `encoder.start()`.
    ///
    /// `outputsPerSecondBuckets[i]` = number of encoded samples whose output callback fired
    /// during second `i` (0-based, where second 0 covers 0..<1 s). The array length equals
    /// `ceil(totalRunDurationSeconds)` — trailing bucket may cover a partial second.
    /// Useful for detecting monotonic decline (`longrunMotion180`) and warmup shape.
    let outputsPerSecondBuckets: [Int]

    /// `OSStatus` returned by setting `kVTCompressionPropertyKey_ExpectedFrameRate`.
    ///
    /// `nil` when the arm did not request `expectedFrameRate`. `noErr` (0) on success.
    /// Any other value indicates HW HEVC did not accept the hint — a finding, not a failure.
    let expectedFrameRateStatus: Int32?

    /// `OSStatus` returned by setting `kVTCompressionPropertyKey_MaxFrameDelayCount`.
    ///
    /// `nil` when the arm did not request `maxFrameDelayCount`. `noErr` (0) on success.
    /// Any other value (e.g. `kVTPropertyNotSupportedErr = -12900`) indicates HW HEVC
    /// does not honour this property — this itself is a finding.
    let maxFrameDelayCountStatus: Int32?
}

// MARK: - LaneConfig

/// Parameters for one encoder lane run.
///
/// Groups the 7 parameters that `runLane` needs so the call-site passes a single struct
/// and stays under SwiftLint's `function_parameter_count` limit.
private struct LaneConfig {
    /// Arm-level settings (pool mode, reordering, max-pending, expected-fps hint).
    let arm: BenchArm
    /// Frame width in pixels.
    let width: Int32
    /// Frame height in pixels.
    let height: Int32
    /// Target frame rate. Must be > 0.
    let fps: Int
    /// Total frames to feed (including warmup).
    let totalFrames: Int
    /// Frames to skip in steady-state accounting.
    let warmupFrames: Int
    /// Lane label for VT telemetry ("bench", "bench-screen", "bench-cam", …).
    let label: String

    /// Creates a lane configuration, asserting invariants at the call site.
    init(arm: BenchArm, width: Int32, height: Int32, fps: Int, totalFrames: Int, warmupFrames: Int, label: String) {
        precondition(fps > 0, "LaneConfig.fps must be > 0")
        precondition(totalFrames >= warmupFrames, "LaneConfig.totalFrames must be >= warmupFrames")
        self.arm = arm
        self.width = width
        self.height = height
        self.fps = fps
        self.totalFrames = totalFrames
        self.warmupFrames = warmupFrames
        self.label = label
    }
}

// MARK: - LaneMetrics (dual-lane result container)

/// Raw metrics collected from one encoder lane.
private struct LaneMetrics {
    let totalOutputs: Int
    let steadyOutputs: Int
    let gateDrops: Int
    let usedHW: Bool
    let unaccounted: Int
    let callbackFrameDropped: Int?
    let callbackFailed: Int?
    let pendingHistogram: [String: Int]
    let pendingTimeline: [[Int]]
    let modalPendingDepth: Int?
    let outputsPerSecondBuckets: [Int]
    let expectedFrameRateStatus: Int32?
    let maxFrameDelayCountStatus: Int32?
}

// MARK: - DualBenchResult

/// JSON result for `dualStaticCam` — two concurrent encoder lanes.
private struct DualBenchResult: Codable {
    let armName: String
    /// Total frames submitted to the screen encoder lane (including warmup).
    let screenFedFrames: Int
    /// Total frames submitted to the camera encoder lane (including warmup).
    let cameraFedFrames: Int
    let screen: LaneSummary
    let camera: LaneSummary
}

/// Codable summary for one lane within a `DualBenchResult`.
private struct LaneSummary: Codable {
    let totalOutputs: Int
    let steadyOutputs: Int
    let steadyMeanOutputsPerSec: Double
    let gateDropsTotal: Int
    let unaccountedFrames: Int
    let callbackFrameDropped: Int?
    let callbackFailed: Int?
    let usedHardwareEncoder: Bool
    let pendingHistogram: [String: Int]
    let pendingTimeline: [[Int]]
    let modalPendingDepth: Int?
    let outputsPerSecondBuckets: [Int]
    /// `OSStatus` returned by setting `kVTCompressionPropertyKey_ExpectedFrameRate`.
    ///
    /// `nil` when the lane did not request `expectedFrameRate`. Non-`noErr` is a finding.
    let expectedFrameRateStatus: Int32?
}

// MARK: - VTServiceRateBenchTests

/// L5 benchmark suite: empirical VT HW HEVC encoder throughput under varying backpressure budgets.
///
/// Twelve arms isolate the hypothesis that the B-frame reorder window (`allowFrameReordering`)
/// causes `kVTCompressionPropertyKey_NumberOfPendingFrames` to grow, backpressure the gate,
/// and drop frames before the service is saturated:
///
///  1. `baselineMotion`        — production settings, motion feed (16 noise bufs)
///  2. `baselineStatic`        — production settings, static feed (1 noise buf repeated)
///  3. `noReorderMotion`       — `allowFrameReordering: false`, motion feed
///  4. `noReorderStatic`       — `allowFrameReordering: false`, static feed
///  5. `gateWideMotion`        — production settings, maxPendingFrames=16, motion (falsifier)
///  6. `staticRotate2`         — production settings, maxPending 4, 2 identical-content buffers cycled
///  7. `staticRotate6`         — production settings, maxPending 4, 6 identical-content buffers cycled
///  8. `expectedFpsStatic`     — production settings, maxPending 4, static 1-buf + ExpectedFrameRate=60
///  9. `dualStaticCam`         — 4K60 screen static + concurrent 1080p30 camera motion (TaskGroup)
/// 10. `gateWideStatic`        — production settings (reordering ON), maxPendingFrames 16, static
/// 11. `delayBounded2Static`   — production settings, maxPendingFrames 4, static, MaxFrameDelayCount=2
/// 12. `longrunMotion180`      — production settings, maxPendingFrames 4, motion, 180 s (bug-B repro)
///
/// All assertions are observational — the suite never asserts throughput numbers so a slow
/// CI machine does not cause false failures; the interesting numbers live in the JSON outputs.
///
/// ## Selective arm runs
///
/// Set `ONSET_BENCH_ARMS` to a comma-separated list of arm names to run only those arms;
/// omit the variable (or leave it empty) to run all arms. Arms not in the list report as
/// genuine SKIPs — never false PASSes. Example:
///
///     TEST_RUNNER_ONSET_RUN_L5_BENCH=1 \
///     TEST_RUNNER_ONSET_BENCH_ARMS="gateWideStatic,delayBounded2Static,longrunMotion180" \
///     xcodebuild test …
@Suite("VTServiceRateBench — L5 VT throughput", .serialized, .timeLimit(.minutes(6)))
// swiftlint:disable:next type_body_length
struct VTServiceRateBenchTests {
    private static let benchLogger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "bench"
    )

    // MARK: - Arms 1–5 (original)

    @Test(
        "baselineMotion — production settings, motion feed",
        .enabled(if: l5BenchEnabled() && armSelected("baselineMotion"))
    )
    func baselineMotion() async throws {
        try await self.runArm(BenchArm(name: "baselineMotion", poolMode: .motion))
    }

    @Test(
        "baselineStatic — production settings, static feed",
        .enabled(if: l5BenchEnabled() && armSelected("baselineStatic"))
    )
    func baselineStatic() async throws {
        try await self.runArm(BenchArm(name: "baselineStatic", poolMode: .static))
    }

    @Test(
        "noReorderMotion — allowFrameReordering: false, motion feed",
        .enabled(if: l5BenchEnabled() && armSelected("noReorderMotion"))
    )
    func noReorderMotion() async throws {
        try await self.runArm(BenchArm(name: "noReorderMotion", poolMode: .motion, allowFrameReordering: false))
    }

    @Test(
        "noReorderStatic — allowFrameReordering: false, static feed",
        .enabled(if: l5BenchEnabled() && armSelected("noReorderStatic"))
    )
    func noReorderStatic() async throws {
        try await self.runArm(BenchArm(name: "noReorderStatic", poolMode: .static, allowFrameReordering: false))
    }

    @Test(
        "gateWideMotion — production settings, maxPendingFrames=16, motion (falsifier)",
        .enabled(if: l5BenchEnabled() && armSelected("gateWideMotion"))
    )
    func gateWideMotion() async throws {
        try await self.runArm(BenchArm(name: "gateWideMotion", poolMode: .motion, maxPendingFrames: 16))
    }

    // MARK: - Arms 6–8

    @Test(
        "staticRotate2 — production settings, 2 identical-content buffers (ping-pong)",
        .enabled(if: l5BenchEnabled() && armSelected("staticRotate2"))
    )
    func staticRotate2() async throws {
        try await self.runArm(BenchArm(name: "staticRotate2", poolMode: .rotate(2)))
    }

    @Test(
        "staticRotate6 — production settings, 6 identical-content buffers (> reorder window)",
        .enabled(if: l5BenchEnabled() && armSelected("staticRotate6"))
    )
    func staticRotate6() async throws {
        try await self.runArm(BenchArm(name: "staticRotate6", poolMode: .rotate(6)))
    }

    @Test(
        "expectedFpsStatic — production settings, static feed, ExpectedFrameRate=60 hint",
        .enabled(if: l5BenchEnabled() && armSelected("expectedFpsStatic"))
    )
    func expectedFpsStatic() async throws {
        try await self.runArm(BenchArm(name: "expectedFpsStatic", poolMode: .static, expectedFrameRate: benchFps))
    }

    // MARK: - Arm 9 (dual-lane)

    @Test(
        "dualStaticCam — 4K60 screen static + 1080p30 camera motion (concurrent)",
        .enabled(if: l5BenchEnabled() && armSelected("dualStaticCam"))
    )
    func dualStaticCam() async throws {
        try await self.runDualArm()
    }

    // MARK: - Arms 10–12 (new)

    /// Arm 10: production settings (reordering ON), maxPendingFrames 16, single static buffer.
    ///
    /// Validates the "keep B-frames, widen the gate" fix candidate. Does the encoder emit
    /// ~60/s on static content when gate stops dropping? If yes — pending grows but
    /// emission is healthy; if no — pending plateaus and emission stays low regardless.
    /// The `pendingTimeline` shape answers this: growing depth + growing outputs = healthy
    /// encode with latency; plateau depth + flat outputs = VT internal stall.
    @Test(
        "gateWideStatic — production reordering ON, maxPendingFrames=16, static",
        .enabled(if: l5BenchEnabled() && armSelected("gateWideStatic"))
    )
    func gateWideStatic() async throws {
        try await self.runArm(BenchArm(name: "gateWideStatic", poolMode: .static, maxPendingFrames: 16))
    }

    /// Arm 11: production settings, maxPendingFrames 4, single static buffer, MaxFrameDelayCount=2.
    ///
    /// Validates the "keep B-frames but bound the reorder window below the gate" fix candidate.
    /// `kVTCompressionPropertyKey_MaxFrameDelayCount` is set to 2 on the live session immediately
    /// after `encoder.start()` (required ordering — the session must exist before the property
    /// can be applied). If `setProperty` returns non-noErr, the status is recorded in the JSON
    /// (`maxFrameDelayCountStatus`) — this itself is a finding (HW HEVC does not honour the
    /// property).
    @Test(
        "delayBounded2Static — production settings, MaxFrameDelayCount=2, static",
        .enabled(if: l5BenchEnabled() && armSelected("delayBounded2Static"))
    )
    func delayBounded2Static() async throws {
        try await self.runArm(BenchArm(name: "delayBounded2Static", poolMode: .static, maxFrameDelayCount: 2))
    }

    /// Arm 12: production settings, motion pool (16 noise bufs), 180 s (10 800 frames).
    ///
    /// Bug-B reproduction check on clean code. Does encoder output/s degrade monotonically
    /// over 3 minutes of worst-case (genuine motion) content?
    ///
    /// The JSON `outputsPerSecondBuckets` array carries all 180 buckets; the report pulls
    /// first-10s vs last-10s mean and flags any monotonic decline.
    ///
    /// Time limit: the suite-level `.timeLimit(.minutes(6))` applies per-test; 180 s ≈ 3 min
    /// is well within budget (confirmed: Swift Testing enforces the shortest trait, and the
    /// suite trait propagates per-test at ~1-min granularity).
    @Test(
        "longrunMotion180 — production settings, motion, 180 s (bug-B repro check)",
        .enabled(if: l5BenchEnabled() && armSelected("longrunMotion180"))
    )
    func longrunMotion180() async throws {
        try await self.runArm(
            BenchArm(name: "longrunMotion180", poolMode: .motion),
            totalFrames: benchLongrunFrames,
            warmupFrames: benchWarmupFrames
        )
    }

    // MARK: - Shared single-lane runner

    /// Runs one measurement arm end-to-end and writes a JSON result to `/tmp/onset-bench/<name>.json`.
    ///
    /// Lifecycle order (load-bearing):
    ///   1. `t0` / anchor — establishes the PTS epoch before any task is spawned.
    ///   2. Pixel-buffer pool allocation.
    ///   3. Capturing factory — wraps `liveSessionFactory` to expose the session for sampling.
    ///   4. Collectors task — must be subscribed BEFORE `start()` so no samples slip through.
    ///   5. `encoder.start()` — activates the session.
    ///   6. Post-start property override (`expectedFrameRate`) if requested.
    ///   7. Pending-frame sampler task — started after start() so the session is live.
    ///   8. Feed loop — submits frames on a real-time grid at `benchFps`.
    ///   9. `encoder.stop()` — drains pending frames, then finishes both AsyncStreams.
    ///  10. Cancel + await sampler task (must happen after stop, before reading timeline).
    ///  11. Await output collectors.
    ///  12. Query OSLogStore for VT callback drops since arm start.
    ///  13. Write JSON result.
    private func runArm(
        _ arm: BenchArm,
        totalFrames: Int = benchTotalFrames,
        warmupFrames: Int = benchWarmupFrames
    ) async throws {
        let config = LaneConfig(
            arm: arm,
            width: benchWidth,
            height: benchHeight,
            fps: benchFps,
            totalFrames: totalFrames,
            warmupFrames: warmupFrames,
            label: "bench"
        )
        let metrics = try await self.runLane(config)
        let steadyDurationSec = Double(totalFrames - warmupFrames) / Double(benchFps)
        let steadyMean = steadyDurationSec > 0 ? Double(metrics.steadyOutputs) / steadyDurationSec : 0

        let result = BenchResult(
            armName: arm.name,
            fedFrames: totalFrames,
            steadyFrames: totalFrames - warmupFrames,
            totalOutputs: metrics.totalOutputs,
            steadyOutputs: metrics.steadyOutputs,
            gateDropsTotal: metrics.gateDrops,
            steadyMeanOutputsPerSec: steadyMean,
            usedHardwareEncoder: metrics.usedHW,
            unaccountedFrames: metrics.unaccounted,
            callbackFrameDropped: metrics.callbackFrameDropped,
            callbackFailed: metrics.callbackFailed,
            pendingHistogram: metrics.pendingHistogram,
            pendingTimeline: metrics.pendingTimeline,
            modalPendingDepth: metrics.modalPendingDepth,
            outputsPerSecondBuckets: metrics.outputsPerSecondBuckets,
            expectedFrameRateStatus: metrics.expectedFrameRateStatus,
            maxFrameDelayCountStatus: metrics.maxFrameDelayCountStatus
        )
        try self.writeSingleJSON(result, name: arm.name)
        self.logSummary(ArmLogSummary(
            name: arm.name,
            fed: totalFrames,
            outputs: metrics.totalOutputs,
            steadyOutputs: metrics.steadyOutputs,
            gateDrops: metrics.gateDrops,
            unaccounted: metrics.unaccounted,
            steadyMean: steadyMean,
            usedHardware: metrics.usedHW,
            callbackDropped: metrics.callbackFrameDropped,
            callbackFailed: metrics.callbackFailed,
            modalPending: metrics.modalPendingDepth
        ))
    }

    // MARK: - Dual-lane runner (arm 9)

    /// Runs arm 9: a 4K60 screen encoder (static, single buffer) concurrently with a 1080p30
    /// camera encoder (motion, 8-buffer pool), using `TaskGroup` for true parallelism.
    ///
    /// Both lanes share the same wall-clock run window. Screen uses production settings
    /// (allowFrameReordering = production default, maxPendingFrames = 4). Camera uses
    /// production settings built for 1920×1080@30 via `EncoderConfigBuilder.build`.
    private func runDualArm() async throws {
        let screenArm = BenchArm(name: "bench-screen", poolMode: .static)
        // Camera: 1080p@30fps, 8-buffer distinct noise pool (spec requires exactly 8 buffers).
        let camArm = BenchArm(name: "bench-cam", poolMode: .noise(8))
        let camTotalFrames = 600 // 20 s × 30 fps

        // TaskGroup: both lanes run concurrently. `try await withThrowingTaskGroup` because
        // either lane can throw on start failure.
        let screenConfig = LaneConfig(
            arm: screenArm,
            width: benchWidth,
            height: benchHeight,
            fps: benchFps,
            totalFrames: benchTotalFrames,
            warmupFrames: benchWarmupFrames,
            label: "bench-screen"
        )
        let camConfig = LaneConfig(
            arm: camArm,
            width: 1920,
            height: 1080,
            fps: 30,
            totalFrames: camTotalFrames,
            warmupFrames: 60,
            label: "bench-cam"
        )
        let (screenMetrics, camMetrics): (LaneMetrics, LaneMetrics) =
            try await withThrowingTaskGroup(of: (String, LaneMetrics).self) { group in
                group.addTask {
                    let laneMetrics = try await self.runLane(screenConfig)
                    return ("screen", laneMetrics)
                }
                group.addTask {
                    let laneMetrics = try await self.runLane(camConfig)
                    return ("cam", laneMetrics)
                }
                var screen: LaneMetrics?
                var cam: LaneMetrics?
                for try await (tag, laneMetrics) in group {
                    if tag == "screen" { screen = laneMetrics } else { cam = laneMetrics }
                }
                guard let screen, let cam else {
                    preconditionFailure("TaskGroup missing results")
                }
                return (screen, cam)
            }

        let screenDurSec = Double(benchTotalFrames - benchWarmupFrames) / Double(benchFps)
        let camDurSec = Double(camTotalFrames - 60) / 30.0

        let result = DualBenchResult(
            armName: "dualStaticCam",
            screenFedFrames: benchTotalFrames,
            cameraFedFrames: camTotalFrames,
            screen: LaneSummary(
                totalOutputs: screenMetrics.totalOutputs,
                steadyOutputs: screenMetrics.steadyOutputs,
                steadyMeanOutputsPerSec: screenDurSec > 0
                    ? Double(screenMetrics.steadyOutputs) / screenDurSec
                    : 0,
                gateDropsTotal: screenMetrics.gateDrops,
                unaccountedFrames: screenMetrics.unaccounted,
                callbackFrameDropped: screenMetrics.callbackFrameDropped,
                callbackFailed: screenMetrics.callbackFailed,
                usedHardwareEncoder: screenMetrics.usedHW,
                pendingHistogram: screenMetrics.pendingHistogram,
                pendingTimeline: screenMetrics.pendingTimeline,
                modalPendingDepth: screenMetrics.modalPendingDepth,
                outputsPerSecondBuckets: screenMetrics.outputsPerSecondBuckets,
                expectedFrameRateStatus: screenMetrics.expectedFrameRateStatus
            ),
            camera: LaneSummary(
                totalOutputs: camMetrics.totalOutputs,
                steadyOutputs: camMetrics.steadyOutputs,
                steadyMeanOutputsPerSec: camDurSec > 0
                    ? Double(camMetrics.steadyOutputs) / camDurSec
                    : 0,
                gateDropsTotal: camMetrics.gateDrops,
                unaccountedFrames: camMetrics.unaccounted,
                callbackFrameDropped: camMetrics.callbackFrameDropped,
                callbackFailed: camMetrics.callbackFailed,
                usedHardwareEncoder: camMetrics.usedHW,
                pendingHistogram: camMetrics.pendingHistogram,
                pendingTimeline: camMetrics.pendingTimeline,
                modalPendingDepth: camMetrics.modalPendingDepth,
                outputsPerSecondBuckets: camMetrics.outputsPerSecondBuckets,
                expectedFrameRateStatus: camMetrics.expectedFrameRateStatus
            )
        )
        try self.writeDualJSON(result)
        Self.benchLogger.notice(
            """
            [dualStaticCam] \
            screen: outputs=\(screenMetrics.totalOutputs, privacy: .public) \
            gateDrops=\(screenMetrics.gateDrops, privacy: .public) \
            unaccounted=\(screenMetrics.unaccounted, privacy: .public) \
            modalPending=\(screenMetrics.modalPendingDepth.map(String.init) ?? "nil", privacy: .public) | \
            cam: outputs=\(camMetrics.totalOutputs, privacy: .public) \
            gateDrops=\(camMetrics.gateDrops, privacy: .public) \
            unaccounted=\(camMetrics.unaccounted, privacy: .public)
            """
        )
    }

    // MARK: - Core single-lane measurement

    /// Runs one encoder lane and returns raw `LaneMetrics`.
    ///
    /// Parameterised so the same implementation serves single arms and both legs of
    /// `dualStaticCam` — no lifecycle duplication. All parameters are packed into
    /// `LaneConfig` to satisfy SwiftLint's `function_parameter_count` limit.
    private func runLane(_ config: LaneConfig) async throws -> LaneMetrics {
        let arm = config.arm
        let width = config.width
        let height = config.height
        let fps = config.fps
        let totalFrames = config.totalFrames
        let warmupFrames = config.warmupFrames
        let label = config.label

        // Build VT settings, overriding allowFrameReordering when the arm requests it.
        var baseSettings = EncoderConfigBuilder.build(
            config: .mvpDefault,
            width: Int(width),
            height: Int(height),
            fps: fps
        )
        if let override = arm.allowFrameReordering {
            baseSettings = VTEncoderSettings(
                averageBitRate: baseSettings.averageBitRate,
                peakDataRate: baseSettings.peakDataRate,
                maxKeyFrameIntervalDurationSeconds: baseSettings.maxKeyFrameIntervalDurationSeconds,
                profileLevel: baseSettings.profileLevel,
                allowFrameReordering: override,
                realTime: baseSettings.realTime,
                bitDepth: baseSettings.bitDepth,
                colorPrimaries: baseSettings.colorPrimaries,
                transferFunction: baseSettings.transferFunction,
                yCbCrMatrix: baseSettings.yCbCrMatrix
            )
        }

        // Establish anchor / T0 before any task is spawned.
        let anchor = HostTimeAnchor.now()

        // Build noise pool according to poolMode.
        let noisePool: [CVPixelBuffer] = self.buildPool(
            mode: arm.poolMode,
            width: Int(width),
            height: Int(height)
        )

        // CapturingFactory: wraps liveSessionFactory and stores the created session for sampling.
        // The box is populated synchronously inside start() before start() returns.
        let sessionBox = SessionBox()
        let capturingFactory: VideoEncoder.SessionFactory = { frameWidth, frameHeight, sink in
            let session = try VideoEncoder.liveSessionFactory(frameWidth, frameHeight, sink)
            sessionBox.store(session)
            return session
        }

        let encoder = VideoEncoder(
            settings: baseSettings,
            width: width,
            height: height,
            fps: fps,
            anchor: anchor,
            maxPendingFrames: arm.maxPendingFrames,
            // selfClocked: false — we drive ingest manually at a real-time grid rate;
            // the clock loop would emit nondeterministic holds against the live anchor.
            selfClocked: false,
            label: label,
            sessionFactory: capturingFactory
        )

        // Subscribe output collectors BEFORE start() so no samples or drops are missed.
        // OSAllocatedUnfairLock is the project-canonical cross-isolation mutable counter
        // (see OnsetTests/CLAUDE.md — FlagBox pattern).
        let totalOutputsLock = OSAllocatedUnfairLock(initialState: 0)
        let steadyOutputsLock = OSAllocatedUnfairLock(initialState: 0)
        let gateDropsLock = OSAllocatedUnfairLock(initialState: 0)

        // Per-second output bucket accumulator. Index = integer seconds since samplesStartTime.
        // Written from the samplesTask; read only after samplesTask completes.
        let outputsPerSecLock = OSAllocatedUnfairLock(initialState: [Int]())

        // Sent from the feed task to the collector via a simple shared nonisolated counter.
        let steadyStartedLock = OSAllocatedUnfairLock(initialState: false)

        // encodedSamples and drops are nonisolated let — no await needed for property access.
        let encodedSamplesStream = encoder.encodedSamples
        let dropsStream = encoder.drops

        // `samplesStartTime` is captured at subscription point (before start()) so the
        // per-second buckets count from when the stream was first live. In practice start()
        // completes before any output callback fires, so the T0 is effectively at start().
        let samplesStartTime = ContinuousClock.now

        let samplesTask = Task {
            var localBuckets = [Int]()
            // Cache the steady-state flag locally once it flips true to avoid a lock
            // acquisition on every subsequent sample. The flag is written once (false→true)
            // by the feed loop; reading it under the lock is only needed until that flip.
            var steadyStarted = false
            for await _ in encodedSamplesStream {
                totalOutputsLock.withLock { $0 += 1 }
                if !steadyStarted {
                    steadyStarted = steadyStartedLock.withLock { $0 }
                }
                if steadyStarted {
                    steadyOutputsLock.withLock { $0 += 1 }
                }
                // Bin the output into a per-second bucket. Integer-second offset since subscription.
                let elapsed = ContinuousClock.now - samplesStartTime
                let bucket = Int(elapsed.components.seconds)
                // Grow the array if this second hasn't been seen yet.
                if bucket >= localBuckets.count {
                    let gap = bucket - localBuckets.count + 1
                    localBuckets.append(contentsOf: repeatElement(0, count: gap))
                }
                localBuckets[bucket] += 1
            }
            let snapshot = localBuckets
            outputsPerSecLock.withLock { $0 = snapshot }
        }

        let dropsTask = Task {
            for await event in dropsStream where event.reason == .encoderBackpressureDrops {
                // Only gate (backpressure) drops are counted for the hypothesis metric.
                gateDropsLock.withLock { $0 += event.count }
            }
        }

        // Capture the arm start time for OSLogStore position (before start, to include
        // any session-creation log entries).
        let armStartDate = Date()

        // Start the encoder — the capturingFactory runs synchronously here, populating sessionBox.
        try await encoder.start()

        let usedHW = await encoder.isUsingHardwareEncoder
        #expect(usedHW, "VT session must use hardware encoder")

        // Post-start properties: applied to the live session immediately after start().
        // Required ordering: session must exist (start() completed) before setProperty;
        // properties must be set before the first frame is fed.
        let (expectedFrameRateStatus, maxFrameDelayCountStatus) = self.applyPostStartProperties(
            arm: arm,
            session: sessionBox.peek(),
            label: label
        )

        // Pending-frame sampler: polls pendingFrameCount() every ~50 ms from arm start until
        // explicitly cancelled. Started AFTER start() so the session is live.
        // Holds two parallel arrays (timeline + histogram accumulator) that are drained to
        // the lock only on cancellation to avoid per-sample lock contention.
        //
        // The sampler runs as an unstructured Task rather than a structured child to avoid
        // blocking the feed loop — it is cancelled explicitly after stop() and awaited before
        // reading the timeline.
        let pendingTimelineLock = OSAllocatedUnfairLock(initialState: [[Int]]())
        let pendingHistogramLock = OSAllocatedUnfairLock(initialState: [String: Int]())

        let samplerTask = Task {
            var localTimeline: [[Int]] = []
            var localHistogram: [String: Int] = [:]
            let samplerStart = ContinuousClock.now
            let interval = Duration.milliseconds(benchSamplerIntervalMs)
            var nextTick = samplerStart + interval

            while !Task.isCancelled {
                // Poll the session; if not yet populated (race between start and first tick),
                // skip this sample rather than blocking.
                if let session = sessionBox.peek() {
                    let depth = session.pendingFrameCount()
                    // `Duration.components` returns (seconds: Int64, attoseconds: Int64).
                    // Convert to milliseconds: secs×1000 + atto÷10^15 (1 ms = 10^15 atto).
                    let elapsed = ContinuousClock.now - samplerStart
                    let elapsedMs = Int(elapsed.components.seconds * 1000)
                        + Int(elapsed.components.attoseconds / benchAttoPerMs)
                    localTimeline.append([elapsedMs, depth])
                    localHistogram["\(depth)", default: 0] += 1
                }
                // Sleep until the next tick. `try?` swallows CancellationError — the outer
                // `while !Task.isCancelled` catches the cancellation on the next iteration.
                try? await Task.sleep(until: nextTick, clock: .continuous)
                nextTick += interval
            }
            // Flush local buffers into the shared locks before the task returns.
            // Explicit capture lists ([localTimeline], [localHistogram]) ensure Swift 6
            // sees a value copy rather than a mutable-var capture in a @Sendable closure.
            let timelineSnapshot = localTimeline
            let histogramSnapshot = localHistogram
            pendingTimelineLock.withLock { $0 = timelineSnapshot }
            pendingHistogramLock.withLock { $0 = histogramSnapshot }
        }

        // Feed loop: submit frames on a real-time grid.
        let clock = ContinuousClock()
        let frameDuration = Duration.seconds(1) / fps
        let feedStart = clock.now

        for slot in 0..<totalFrames {
            // Mark steady-state start after warmup.
            if slot == warmupFrames {
                steadyStartedLock.withLock { $0 = true }
            }

            let slotOffset = CMTimeMake(
                value: CMTimeValue(slot),
                timescale: Int32(fps)
            )
            let pts = CMTimeAdd(anchor.anchorTime, slotOffset)
            let pixelBuffer = noisePool[slot % noisePool.count]
            let frame = VideoFrame(
                pixelBuffer: pixelBuffer,
                ptsHostTime: pts,
                isHoldRepeat: false
            )

            await encoder.ingest(frame)

            // Sleep until the next grid deadline, skipping if we're already behind.
            let nextDeadline = feedStart + frameDuration * (slot + 1)
            try? await Task.sleep(until: nextDeadline, clock: clock)
        }

        // Stop: drains pending frames then finishes both AsyncStreams.
        await encoder.stop()

        // Cancel and await the sampler BEFORE reading the timeline — the sampler flushes
        // its local buffers into the shared locks in its body after cancellation.
        samplerTask.cancel()
        await samplerTask.value

        // Await collectors (safe: both streams are finished by stop()).
        await samplesTask.value
        await dropsTask.value

        let totalOutputs = totalOutputsLock.withLock { $0 }
        let steadyOutputs = steadyOutputsLock.withLock { $0 }
        let gateDrops = gateDropsLock.withLock { $0 }
        let pendingHistogram = pendingHistogramLock.withLock { $0 }
        let pendingTimeline = pendingTimelineLock.withLock { $0 }
        let outputsPerSecondBuckets = outputsPerSecLock.withLock { $0 }

        // Compute derived metrics.
        let unaccounted = totalFrames - totalOutputs - gateDrops
        let modalDepth: Int? = pendingHistogram
            .max { $0.value < $1.value }
            .flatMap { Int($0.key) }

        // Query OSLogStore for VT callback drop evidence in this arm's window.
        let (callbackDropped, callbackFailed) = self.queryCallbackDrops(since: armStartDate)

        // Observational assertions — no throughput thresholds.
        #expect(totalOutputs > 0, "encoder must have produced at least one output")
        #expect(
            gateDrops + totalOutputs <= totalFrames,
            "gate drops + outputs must not exceed fed frames"
        )

        return LaneMetrics(
            totalOutputs: totalOutputs,
            steadyOutputs: steadyOutputs,
            gateDrops: gateDrops,
            usedHW: usedHW,
            unaccounted: unaccounted,
            callbackFrameDropped: callbackDropped,
            callbackFailed: callbackFailed,
            pendingHistogram: pendingHistogram,
            pendingTimeline: pendingTimeline,
            modalPendingDepth: modalDepth,
            outputsPerSecondBuckets: outputsPerSecondBuckets,
            expectedFrameRateStatus: expectedFrameRateStatus,
            maxFrameDelayCountStatus: maxFrameDelayCountStatus
        )
    }

    // MARK: - Pool builder

    /// Builds a pixel-buffer pool according to `PoolMode`.
    private func buildPool(mode: BenchArm.PoolMode, width: Int, height: Int) -> [CVPixelBuffer] {
        switch mode {
        case .motion:
            return (0..<benchNoiseBufferCount).map { _ in
                makeNoisyPixelBuffer(width: width, height: height)
            }

        case .static:
            return [makeNoisyPixelBuffer(width: width, height: height)]

        case let .rotate(count):
            // All buffers share the same pixel content (copied from a single noise seed)
            // but are distinct CVPixelBuffer objects. This isolates same-buffer identity
            // (which VT tracks via IOSurface handle) from content motion.
            // Destinations are allocated without noise fill — copyPlanes overwrites every
            // plane byte, so pre-filling with random data would be discarded immediately.
            let seed = makeNoisyPixelBuffer(width: width, height: height)
            return (0..<count).map { _ in
                let buf = makePixelBuffer(width: width, height: height)
                // Overwrite with seed content so all buffers are identical in encoded content.
                copyPlanes(src: seed, dst: buf)
                return buf
            }

        case let .noise(count):
            // Distinct noise buffers with explicit pool size — genuine motion, configurable depth.
            return (0..<count).map { _ in
                makeNoisyPixelBuffer(width: width, height: height)
            }
        }
    }

    // MARK: - Post-start property application

    /// Applies optional VT session properties that must be set after `encoder.start()` returns
    /// and before the first frame is fed.
    ///
    /// Extracted from `runLane` to keep cyclomatic complexity within the SwiftLint limit.
    ///
    /// - Parameters:
    ///   - arm: The arm configuration carrying the optional property requests.
    ///   - session: The live compression session captured by `SessionBox`; `nil` is tolerated
    ///     (properties are silently skipped) so the call site needs no guard.
    ///   - label: Lane label used in log messages.
    /// - Returns: A tuple `(expectedFrameRateStatus, maxFrameDelayCountStatus)` where each
    ///   element is the `OSStatus` from the corresponding `setProperty` call, or `nil` when
    ///   the arm did not request that property.
    private func applyPostStartProperties(
        arm: BenchArm,
        session: (any CompressionSession)?,
        label: String
    )
    -> (expectedFrameRateStatus: Int32?, maxFrameDelayCountStatus: Int32?) {
        guard let session else { return (nil, nil) }

        var efrStatus: Int32?
        if let expectedFps = arm.expectedFrameRate {
            let fpsNumber = expectedFps as CFNumber
            let status = session.setProperty(
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: fpsNumber
            )
            efrStatus = status
            if status != noErr {
                Self.benchLogger.warning(
                    "[\(label, privacy: .public)] ExpectedFrameRate set failed: status \(status, privacy: .public)"
                )
            }
        }

        guard let maxDelay = arm.maxFrameDelayCount else { return (efrStatus, nil) }
        let delayNumber = maxDelay as CFNumber
        let status = session.setProperty(
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: delayNumber
        )
        // Capture unconditionally — non-noErr (e.g. kVTPropertyNotSupportedErr = -12900)
        // means HW HEVC does not honour this property; that itself is a finding.
        Self.benchLogger.notice(
            """
            [\(label, privacy: .public)] \
            MaxFrameDelayCount=\(maxDelay, privacy: .public) \
            setProperty status=\(status, privacy: .public)
            """
        )
        return (efrStatus, status)
    }

    // MARK: - OSLogStore query

    /// Queries the current-process OSLog for VideoEncoder.Session entries since `startDate`.
    ///
    /// Returns `(callbackFrameDropped, callbackFailed)` counts. Both fields are `nil` when the
    /// log store is unavailable (e.g. insufficient entitlements in the test process), in which
    /// case `unaccountedFrames` in `BenchResult` remains the only discriminator.
    ///
    /// The log messages being counted are emitted by `LiveCompressionSession`'s output
    /// callback:
    ///   - "frameDropped": `infoFlags.contains(.frameDropped)` path.
    ///   - "failed": `status ≠ noErr` path ("Encode output callback failed").
    private func queryCallbackDrops(since startDate: Date) -> (Int?, Int?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: startDate)
            let entries = try store.getEntries(
                at: position,
                matching: NSPredicate(
                    format: "subsystem == %@ AND category == %@",
                    "dev.androidbroadcast.Onset",
                    "VideoEncoder.Session"
                )
            )
            var dropped = 0
            var failed = 0
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let msg = logEntry.composedMessage
                if msg.contains("frameDropped") { dropped += 1 }
                if msg.contains("failed") { failed += 1 }
            }
            return (dropped, failed)
        } catch {
            // OSLogStore is available on macOS 12+ for .currentProcessIdentifier scope,
            // but the test process may lack the com.apple.logging.local-store entitlement
            // when run without full signing. Fall through to nil so the caller documents
            // unaccountedFrames without callback counts.
            Self.benchLogger.warning(
                "OSLogStore query failed — callbackDropped/callbackFailed unavailable: \(error, privacy: .public)"
            )
            return (nil, nil)
        }
    }

    // MARK: - JSON writers

    /// Writes a single-arm `BenchResult` to `/tmp/onset-bench/<name>.json`.
    private func writeSingleJSON(_ result: BenchResult, name: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(result)
        try FileManager.default.createDirectory(
            atPath: benchOutputDir,
            withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: "\(benchOutputDir)/\(name).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Self.benchLogger.error(
                "[\(name, privacy: .public)] failed to write JSON result: \(error, privacy: .public)"
            )
            throw error
        }
    }

    /// Writes a `DualBenchResult` to `/tmp/onset-bench/dualStaticCam.json`.
    private func writeDualJSON(_ result: DualBenchResult) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(result)
        try FileManager.default.createDirectory(
            atPath: benchOutputDir,
            withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: "\(benchOutputDir)/dualStaticCam.json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Self.benchLogger.error(
                "[dualStaticCam] failed to write JSON result: \(error, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Log summary

    /// Summary values for one lane arm — groups the many log-notice fields under a single
    /// call-site argument to keep `logSummary` within SwiftLint's `function_parameter_count` limit.
    private struct ArmLogSummary {
        let name: String
        let fed: Int
        let outputs: Int
        let steadyOutputs: Int
        let gateDrops: Int
        let unaccounted: Int
        let steadyMean: Double
        let usedHardware: Bool
        let callbackDropped: Int?
        let callbackFailed: Int?
        let modalPending: Int?
    }

    /// Emits a one-line summary notice for a single-lane arm.
    private func logSummary(_ summary: ArmLogSummary) {
        Self.benchLogger.notice(
            """
            [\(summary.name, privacy: .public)] \
            fed=\(summary.fed, privacy: .public) \
            outputs=\(summary.outputs, privacy: .public) \
            steadyOutputs=\(summary.steadyOutputs, privacy: .public) \
            gateDrops=\(summary.gateDrops, privacy: .public) \
            unaccounted=\(summary.unaccounted, privacy: .public) \
            steadyMean=\(summary.steadyMean, format: .fixed(precision: 2), privacy: .public) fps \
            hw=\(summary.usedHardware, privacy: .public) \
            modalPending=\(summary.modalPending.map(String.init) ?? "nil", privacy: .public) \
            cbDropped=\(summary.callbackDropped.map(String.init) ?? "nil", privacy: .public) \
            cbFailed=\(summary.callbackFailed.map(String.init) ?? "nil", privacy: .public)
            """
        )
    }
}

// swiftlint:enable function_body_length
// file_length stays disabled through EOF: it is a whole-file rule, re-enabling before the
// last line would re-trigger on the total count. The file intentionally collects arm config,
// result types, pixel-buffer fixtures, and the runner in one cohesive bench concern.
