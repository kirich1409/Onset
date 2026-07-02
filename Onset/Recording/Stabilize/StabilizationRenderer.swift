// StabilizationRenderer.swift
// Onset
//
// #297 — impure GPU half of the camera-stabilization stage.
//
// `StabilizationStage` is the protocol seam between the orchestrating actor
// (`StabilizingVideoSource`) and the GPU work — the project's DI-seam pattern; the L2 decorator
// tests substitute a fake stage (a live Vision/Metal stack is untestable without hardware).
// `StabilizationRenderer` is the live implementation: Vision translational registration on an
// upscale + CoreImage translate/crop/scale-back render into a pooled NV12 buffer.
//
// file_length: the seam protocol, the error taxonomy it throws, and the live renderer form one
// GPU-boundary unit — a fake stage implements the protocol against exactly these errors, so
// splitting them apart would decouple the contract from its failure modes.
// swiftlint:disable file_length
//
// Isolation: (mirrors `LiveCompressionSession` / `VideoOutputShim`) a dedicated SERIAL
// DispatchQueue (`qos: .userInitiated`) owns every mutable field and executes all Vision/CI work —
// 30 ms of synchronous Vision per frame must never run in the Swift Concurrency cooperative pool
// (actor starvation). Async methods bridge onto the queue via `withCheckedContinuation`
// (checked, not unsafe; single in-flight is guaranteed by the caller's design: a depth-1 slot +
// a single work task). Only `CVPixelBuffer` references cross the bridge — the same read-only
// invariant `VideoFrame` documents for its `@unchecked Sendable`.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import os
import Vision

// MARK: - StabilizationError

/// Setup errors of the stabilization stage, wrapped into
/// `RecordingError.captureSetupFailed(StabilizationError…)` by `StabilizingVideoSource.start`.
///
/// A DISTINCT type (pattern: `CameraSourceError`) so the start-failure alert can reliably tell a
/// stabilization failure from a real camera failure: a generic inner error would force the UI
/// into the "toggle is ON → blame stabilization" heuristic, which mis-instructs the user when the
/// camera itself is broken.
nonisolated enum StabilizationError: Error {
    /// No Metal device is available for the CoreImage render context.
    case metalUnavailable

    /// The output `CVPixelBufferPool` could not be created (wrapped `CVReturn`).
    case outputPoolCreationFailed(CVReturn)

    /// An estimation buffer could not be allocated (wrapped `CVReturn`). Thrown by
    /// `activateEstimation` — the caller degrades to bypass instead of failing the session.
    case estimationBufferAllocationFailed(CVReturn)
}

// MARK: - StabilizationStageError

/// Per-frame errors of the stabilization stage.
nonisolated enum StabilizationStageError: Error {
    /// The output pool refused an allocation at its threshold. The frame is dropped
    /// (`DropEvent(.stabilizeCamera, .stabilizationDrops)`) but the error does NOT feed the
    /// bypass triggers — pool exhaustion is a downstream-congestion symptom bypass cannot cure.
    case outputPoolExhausted

    /// The CoreImage render failed (Metal / command buffer). The frame is dropped and the
    /// shared consecutive-error counter (Vision + render) is incremented.
    case renderFailed

    /// Vision registration failed or produced no observation. The frame passes through with
    /// the PREVIOUS correction (freeze) and the shared consecutive-error counter increments.
    case estimationFailed
}

// MARK: - StabilizationStage

/// The estimation+render seam of the stabilization stage.
///
/// Call ordering contract (enforced by `StabilizingVideoSource`):
/// `prepare()` → [`render` during warm-up] → `activateEstimation(estScale:)` →
/// [`estimateShift` + `render` per frame] → (`deactivateEstimation()` on bypass) → `finish()`.
/// All methods are serialized by the caller — implementations may assume no concurrent calls.
nonisolated protocol StabilizationStage: Sendable {
    /// Allocates the render resources (CI context, output pool). Called BEFORE the wrapped
    /// source starts, so a throw here has no side effects to unwind.
    func prepare() async throws

    /// Allocates the estimation buffers for the warm-up-chosen scale (2 or 3).
    /// Buffers are `(1920×estScale) × (1080×estScale)` NV12 — allocated only now, after the
    /// scale is known (#297: "буферы оценки аллоцируются после выбора").
    func activateEstimation(estScale: Int) async throws

    /// Upscales `frame` into the current estimation buffer and registers it against the
    /// previously ingested frame.
    ///
    /// SIGN CONTRACT (AC-6, single definition for live AND fake implementations): the returned
    /// shift is the OBSERVED CONTENT DISPLACEMENT of `frame` relative to the previous frame —
    /// content that moved +Δ px yields shift = +Δ. The smoother then produces
    /// `correction ≈ −shift`, which translates the content back. Any estimator whose native
    /// convention differs (Vision's `alignmentTransform` maps the floating image ONTO the
    /// reference, i.e. −displacement) must convert at ITS OWN boundary, never downstream.
    /// Pinned end-to-end by `StabilizationSignTests`.
    ///
    /// - Returns: The content displacement in ESTIMATION-BUFFER pixels, or `nil` for the
    ///   first frame after activation (no pair yet).
    /// - Throws: `StabilizationStageError.estimationFailed` on a Vision failure. The frame
    ///   still becomes the "previous" of the next pair.
    func estimateShift(of frame: VideoFrame) async throws -> StabilizationVector?

    /// Renders `frame` with `correction` (PLAN pixels): translate → clamp → session-fixed crop →
    /// isotropic scale-back → NEW pooled NV12 buffer. Every frame goes through this render —
    /// raw passthrough is forbidden (zoom-flicker, spike red flag #1). The input buffer is
    /// read-only; `ptsHostTime` / `isHoldRepeat` are carried over verbatim.
    func render(_ frame: VideoFrame, correction: StabilizationVector) async throws -> VideoFrame

    /// Stops estimation and releases the estimation buffers (bypass). Render-only operation
    /// continues; `estimateShift` is never called again this session.
    func deactivateEstimation() async

    /// Releases every resource (pool, context, buffers). Terminal.
    func finish() async
}

// MARK: - StabilizationRenderer

/// Live `StabilizationStage`: Vision + CoreImage(Metal) on a dedicated serial queue.
///
/// `@unchecked Sendable` rationale: every mutable stored property is confined to `workQueue`
/// (a serial queue) — written in `prepare()` / `activateEstimation()` / per-frame methods, all of
/// which execute exclusively on that queue. The immutable geometry (`cropRect`, `scaleBack`,
/// output dimensions) is `let`. The queue is the synchronization mechanism (pattern:
/// `VideoOutputShim`).
nonisolated final class StabilizationRenderer: StabilizationStage, @unchecked Sendable {
    // MARK: Constants

    /// Output-pool allocation threshold (`kCVPixelBufferPoolAllocationThresholdKey`).
    /// Budget: encoder `maxPendingFrames` 4 + in-flight 1 + VideoToolbox retention 2 +
    /// encoder `lastPixelBuffer` (CFR hold-repeat keeps the last real frame) 1 + the stage's
    /// output-stream depth `.bufferingNewest(4)` under encoder backpressure = 12.
    private static let outputPoolAllocationThreshold = 12

    private static let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "StabilizationRenderer"
    )

    /// Signposter for the AC-8 latency intervals ("stabilize-estimate" / "stabilize-render"),
    /// visible in Instruments' os_signpost track.
    private static let signposter = OSSignposter(
        subsystem: "dev.androidbroadcast.Onset",
        category: "Stabilization"
    )

    // MARK: Immutable geometry

    /// Session-fixed crop rect in plan pixels (from `ResolvedCameraPlan.StabilizationPlan`).
    private let cropRect: CGRect

    /// Isotropic scale factor restoring the crop to plan dimensions.
    private let scaleBack: Double

    /// Planned output width, px (equals the input frame width).
    private let outputWidth: Int

    /// Planned output height, px.
    private let outputHeight: Int

    /// The serial work queue owning all Vision/CI work and every mutable field below.
    private let workQueue = DispatchQueue(
        label: "dev.androidbroadcast.Onset.Stabilization.work",
        qos: .userInitiated
    )

    // MARK: Queue-confined state

    /// Metal-backed CoreImage context. Created in `prepare()`.
    /// `nonisolated(unsafe)`: confined to `workQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var context: CIContext?

    /// Output NV12 buffer pool. Created in `prepare()`.
    /// `nonisolated(unsafe)`: confined to `workQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var pool: CVPixelBufferPool?

    /// Estimation buffer holding the PREVIOUS frame's upscale. Allocated (together with
    /// `currentEstimation`) in `activateEstimation`; the pair is swapped after every frame so
    /// each frame is upscaled exactly once and serves both of its pairs.
    /// `nonisolated(unsafe)`: confined to `workQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var previousEstimation: CVPixelBuffer?

    /// Estimation buffer the CURRENT frame is upscaled into (see `previousEstimation`).
    /// `nonisolated(unsafe)`: confined to `workQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var currentEstimation: CVPixelBuffer?

    /// `true` once `previousEstimation` holds a real upscale — the first frame after activation
    /// has no pair, so Vision runs only from the second frame on.
    /// `nonisolated(unsafe)`: confined to `workQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var hasReferenceFrame = false

    // MARK: Init

    /// Creates the renderer for one session's fixed geometry. No allocation happens here —
    /// resources are created in `prepare()` per the stage lifecycle contract.
    ///
    /// - Parameters:
    ///   - stabilization: The resolved session geometry (crop + scale-back).
    ///   - outputWidth: Planned output width in pixels.
    ///   - outputHeight: Planned output height in pixels.
    nonisolated init(
        stabilization: ResolvedCameraPlan.StabilizationPlan,
        outputWidth: Int,
        outputHeight: Int
    ) {
        self.cropRect = stabilization.cropRect
        self.scaleBack = stabilization.scaleBack
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    // MARK: StabilizationStage

    nonisolated func prepare() async throws {
        try await self.onQueueThrowing {
            guard let device = MTLCreateSystemDefaultDevice() else {
                Self.logger.error("prepare: no Metal device available")
                throw StabilizationError.metalUnavailable
            }
            // `unsafe`: CVPixelBufferPoolCreate writes through an out-pointer
            // (SWIFT_STRICT_MEMORY_SAFETY = YES).
            var createdPool: CVPixelBufferPool?
            let status = unsafe CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                Self.outputPixelBufferAttributes(width: self.outputWidth, height: self.outputHeight),
                &createdPool
            )
            guard status == kCVReturnSuccess, let createdPool else {
                Self.logger.error("prepare: output pool creation failed status=\(status)")
                throw StabilizationError.outputPoolCreationFailed(status)
            }
            unsafe self.pool = createdPool
            // Color management disabled: the stage is geometry-only (translate/crop/scale-back;
            // Vision reads luma only, no color transform is ever applied), so the default
            // NV12→linear-RGB→NV12 working-space round trip on every render is pure overhead.
            // Scaling then interpolates in video (non-linear) space — the standard CoreImage
            // real-time-video tradeoff, imperceptible for sub-pixel stabilization; output
            // color-neutrality confirmed in L5 (#298).
            unsafe self.context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        }
    }

    nonisolated func activateEstimation(estScale: Int) async throws {
        let width = StabilizationTuning.estimationReferenceWidth * estScale
        let height = StabilizationTuning.estimationReferenceHeight * estScale
        try await self.onQueueThrowing {
            // Both halves of the double buffer are allocated up front (≈56 MB total @3×) —
            // the spec's stage memory budget accounts for exactly these two buffers.
            unsafe self.previousEstimation = try Self.makeEstimationBuffer(width: width, height: height)
            unsafe self.currentEstimation = try Self.makeEstimationBuffer(width: width, height: height)
            unsafe self.hasReferenceFrame = false
            Self.logger.info("estimation activated: estScale=\(estScale) buffers=\(width)x\(height)")
        }
    }

    nonisolated func estimateShift(of frame: VideoFrame) async throws -> StabilizationVector? {
        try await self.onQueueThrowing {
            let state = Self.signposter.beginInterval("stabilize-estimate")
            defer { Self.signposter.endInterval("stabilize-estimate", state) }
            return try self.estimateOnQueue(frame)
        }
    }

    nonisolated func render(_ frame: VideoFrame, correction: StabilizationVector) async throws -> VideoFrame {
        try await self.onQueueThrowing {
            let state = Self.signposter.beginInterval("stabilize-render")
            defer { Self.signposter.endInterval("stabilize-render", state) }
            return try self.renderOnQueue(frame, correction: correction)
        }
    }

    nonisolated func deactivateEstimation() async {
        await self.onQueue {
            unsafe self.previousEstimation = nil
            unsafe self.currentEstimation = nil
            Self.logger.notice("estimation deactivated (bypass)")
        }
    }

    nonisolated func finish() async {
        await self.onQueue {
            unsafe self.previousEstimation = nil
            unsafe self.currentEstimation = nil
            unsafe self.pool = nil
            unsafe self.context = nil
        }
    }

    // MARK: Queue bridging

    /// Runs `work` on the serial work queue, bridging the result back through a checked
    /// continuation. Single in-flight is guaranteed by the caller (depth-1 slot + one work task),
    /// so the continuation is resumed exactly once per call by construction.
    nonisolated private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            self.workQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Throwing variant of `onQueue`.
    nonisolated private func onQueueThrowing<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws
    -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            self.workQueue.async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }

    // MARK: Estimation (on queue)

    /// Upscales `frame` into the current estimation buffer and registers it against the
    /// previous one. Runs on `workQueue`.
    private func estimateOnQueue(_ frame: VideoFrame) throws -> StabilizationVector? {
        guard let context = unsafe self.context,
              let target = unsafe self.currentEstimation,
              let reference = unsafe self.previousEstimation
        else {
            // Estimation not activated — programming error surfaced as a per-frame failure
            // rather than a crash (stability over one frame).
            throw StabilizationStageError.estimationFailed
        }
        // Upscale ONCE per frame: this buffer serves as `current` for pair (N−1, N) and as
        // `previous` for pair (N, N+1) after the swap below.
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let scaleX = Double(CVPixelBufferGetWidth(target)) / Double(CVPixelBufferGetWidth(frame.pixelBuffer))
        let scaleY = Double(CVPixelBufferGetHeight(target)) / Double(CVPixelBufferGetHeight(frame.pixelBuffer))
        context.render(source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), to: target)

        defer {
            // Swap: current becomes previous (the pair's reference for the NEXT frame); the old
            // previous buffer is recycled as the next upscale target — its contents are fully
            // overwritten by the next render.
            unsafe self.previousEstimation = target
            unsafe self.currentEstimation = reference
        }

        guard unsafe self.hasReferenceFrame else {
            // First frame after activation — no pair yet; it becomes the reference via the swap.
            unsafe self.hasReferenceFrame = true
            return nil
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: target)
        let handler = VNImageRequestHandler(cvPixelBuffer: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Self.logger.warning("Vision registration failed: \(String(describing: error))")
            throw StabilizationStageError.estimationFailed
        }
        guard let observation = request.results?.first else {
            throw StabilizationStageError.estimationFailed
        }
        // Sign conversion at the Vision boundary (AC-6): `alignmentTransform` is the transform
        // that maps the FLOATING image (current) onto the REFERENCE (previous) — the INVERSE of
        // the content displacement. The stage contract (see `StabilizationStage.estimateShift`)
        // is "shift = observed content displacement", so negate here. Empirically pinned by
        // StabilizationSignTests: without the negation the rendered correction lands ~2Δ away.
        let transform = observation.alignmentTransform
        return StabilizationVector(deltaX: -Double(transform.tx), deltaY: -Double(transform.ty))
    }

    // MARK: Render (on queue)

    /// Full per-frame render: translate(correction) → clampToExtent → crop(session-fixed rect) →
    /// isotropic scale-back → NEW pooled NV12 buffer. Runs on `workQueue`.
    private func renderOnQueue(_ frame: VideoFrame, correction: StabilizationVector) throws -> VideoFrame {
        guard let context = unsafe self.context, let pool = unsafe self.pool else {
            throw StabilizationStageError.renderFailed
        }
        // `unsafe`: CVPixelBufferPoolCreatePixelBufferWithAuxAttributes writes via out-pointer.
        var output: CVPixelBuffer?
        let status = unsafe CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            Self.poolAuxAttributes(),
            &output
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw StabilizationStageError.outputPoolExhausted
        }
        guard status == kCVReturnSuccess, let output else {
            Self.logger.error("render: pool allocation failed status=\(status)")
            throw StabilizationStageError.renderFailed
        }

        // The input buffer is READ-ONLY (VideoFrame invariant); every op below is functional
        // CIImage composition rendered into the fresh pooled buffer.
        let translated = CIImage(cvPixelBuffer: frame.pixelBuffer)
            .transformed(by: CGAffineTransform(translationX: correction.deltaX, y: correction.deltaY))
            .clampedToExtent()
            .cropped(to: self.cropRect)
        // Map the crop rect onto the output extent: shift its origin to zero, then scale back
        // isotropically to the planned dimensions (translate FIRST, then scale).
        let toOutput = CGAffineTransform(translationX: -self.cropRect.minX, y: -self.cropRect.minY)
            .concatenating(CGAffineTransform(scaleX: self.scaleBack, y: self.scaleBack))
        // clampedToExtent + crop-to-output: the isotropic scale-back only covers the output
        // extent exactly for the canonical 1920/3840 plan widths; other even widths leave a
        // sub-pixel gap on one axis (e.g. 1280×720 → crop 1260×708 → scaleBack 1280/1260 →
        // scaled height 719.24 < 720) that CIContext.render never writes, exposing stale pooled
        // buffer contents as a flickering edge line. This bounds the render to the full output
        // rect (edge-clamped fill for the gap; a no-op for the canonical widths).
        let outputRect = CGRect(x: 0, y: 0, width: self.outputWidth, height: self.outputHeight)
        context.render(translated.transformed(by: toOutput).clampedToExtent().cropped(to: outputRect), to: output)

        // PTS and hold flag carry over verbatim — the single-T0 invariant (AC-7).
        return VideoFrame(pixelBuffer: output, ptsHostTime: frame.ptsHostTime, isHoldRepeat: frame.isHoldRepeat)
    }

    // MARK: Buffer attributes

    /// Pixel-buffer attributes of the output pool: NV12 video-range (the VTCompressionSession
    /// native format — BGRA would force a per-frame conversion in the encoder), IOSurface-backed,
    /// Metal-compatible for the CI render target.
    nonisolated private static func outputPixelBufferAttributes(width: Int, height: Int) -> CFDictionary {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
    }

    /// Aux attributes for pooled allocations: the fixed threshold turns unbounded pool growth
    /// under downstream stall into an explicit `outputPoolExhausted` drop.
    nonisolated private static func poolAuxAttributes() -> CFDictionary {
        [
            kCVPixelBufferPoolAllocationThresholdKey: self.outputPoolAllocationThreshold,
        ] as CFDictionary
    }

    /// Creates one NV12 estimation buffer (IOSurface-backed, Metal-compatible).
    nonisolated private static func makeEstimationBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        // `unsafe`: CVPixelBufferCreate writes through an out-pointer.
        var buffer: CVPixelBuffer?
        let status = unsafe CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            Self.outputPixelBufferAttributes(width: width, height: height),
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            Self.logger.error("estimation buffer allocation failed status=\(status) size=\(width)x\(height)")
            throw StabilizationError.estimationBufferAllocationFailed(status)
        }
        return buffer
    }
}
