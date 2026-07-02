// StabilizationSignTests.swift
// OnsetTests
//
// AC-6 (#297): the correction sign is pinned by an executable test on the REAL Vision +
// CIContext(Metal) stack — "на синтетической паре буферов со сдвигом (+Δ) этап выдаёт
// коррекцию (−Δ)". The check is end-to-end and falsifiable: frame B is frame A's pattern
// shifted by +Δ; the estimate→smoother→render chain must bring B's rendered content back
// onto A's rendered position. A flipped sign would move the content 2Δ away and fail loudly.
//
// This suite doubles as the CI smoke of the Vision/Metal stack (spec: first step of #297).
// If the CI runner has no usable Metal device, `prepare()` throws `metalUnavailable` and the
// suite fails — the spec's fallback then moves it to a local preflight gate.
//
// Also pins AC-7's unit-checkable half: the output buffer comes from the stage's own pool in
// NV12/420v at the PLANNED dimensions (scale-back, not "smaller output"), with the PTS and
// hold flag carried verbatim.

import CoreGraphics
import CoreMedia
import CoreVideo
@testable import Onset
import Testing

// MARK: - Synthetic pattern frames

/// Canonical 1080p plan used by the suite.
private let planWidth = 1920
private let planHeight = 1080

/// Draws the deterministic test pattern — a dark background with a fixed constellation of
/// bright rectangles — shifted by `(offsetX, offsetY)` pixels, into a BGRA buffer.
/// The WHOLE pattern shifts together: Vision estimates the dominant global translation.
private func makePatternFrame(
    offsetX: Int,
    offsetY: Int,
    ptsSeconds: Double,
    isHoldRepeat: Bool = false
)
-> VideoFrame {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        planWidth,
        planHeight,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        preconditionFailure("BGRA buffer alloc failed: \(status)")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: planWidth,
        height: planHeight,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        preconditionFailure("CGContext creation failed")
    }

    context.setFillColor(CGColor(gray: 0.08, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: planWidth, height: planHeight))

    // Deterministic constellation: 24 bright rectangles spread over the safe interior
    // (clear of the crop margins), pseudo-random via fixed integer arithmetic.
    context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    for index in 0..<24 {
        let baseX = 120 + (index * 397) % 1500
        let baseY = 120 + (index * 211) % 760
        let side = 30 + (index * 53) % 50
        context.fill(CGRect(
            x: baseX + offsetX,
            y: baseY + offsetY,
            width: side,
            height: side
        ))
    }
    return VideoFrame(
        pixelBuffer: buffer,
        ptsHostTime: CMTime(seconds: ptsSeconds, preferredTimescale: 600),
        isHoldRepeat: isHoldRepeat
    )
}

/// Computes the brightness centroid of a 420v buffer's luma plane (threshold 128, 2 px
/// sampling step). Orientation-agnostic: the same measurement is applied to every frame, so
/// centroid DIFFERENCES are valid regardless of coordinate conventions.
private func lumaCentroid(of buffer: CVPixelBuffer) -> (x: Double, y: Double) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
        preconditionFailure("no luma plane")
    }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let bytes = base.assumingMemoryBound(to: UInt8.self)

    var sumX = 0.0
    var sumY = 0.0
    var count = 0.0
    var row = 0
    while row < height {
        var column = 0
        while column < width {
            if bytes[row * stride + column] > 128 {
                sumX += Double(column)
                sumY += Double(row)
                count += 1
            }
            column += 2
        }
        row += 2
    }
    precondition(count > 0, "no bright pixels found — the pattern did not render")
    return (sumX / count, sumY / count)
}

/// Euclidean distance between two centroids.
private func distance(_ lhs: (x: Double, y: Double), _ rhs: (x: Double, y: Double)) -> Double {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return (dx * dx + dy * dy).squareRoot()
}

// MARK: - Suite

@Suite("Stabilization sign & output format — real Vision+CI stack (AC-6/AC-7)", .timeLimit(.minutes(2)))
struct StabilizationSignTests {
    /// Builds a live renderer for the canonical 1080p plan.
    private func makeRenderer() -> StabilizationRenderer {
        StabilizationRenderer(
            stabilization: CapabilityResolver.makeStabilizationPlan(
                planWidth: planWidth,
                planHeight: planHeight
            ),
            outputWidth: planWidth,
            outputHeight: planHeight
        )
    }

    @Test("AC-6: for a +Δ content shift the chain renders B back onto A (correction = −Δ end-to-end)")
    func sign_correctionCancelsContentShift() async throws {
        let renderer = self.makeRenderer()
        try await renderer.prepare()
        try await renderer.activateEstimation(estScale: 2)

        let shiftX = 8
        let shiftY = 4
        let frameA = makePatternFrame(offsetX: 0, offsetY: 0, ptsSeconds: 0.0)
        let frameB = makePatternFrame(offsetX: shiftX, offsetY: shiftY, ptsSeconds: 0.05)

        // Estimate the pair on the real Vision stack (2× upscale of the 1080p working res).
        let first = try await renderer.estimateShift(of: frameA)
        #expect(first == nil) // no pair yet
        let rawShift = try #require(try await renderer.estimateShift(of: frameB))

        // The measured raw shift magnitude must match the stimulus (×2 estimation coords) —
        // the stimulus-validity gate of this test (mirrors the AC-1 OFF-gate philosophy).
        let estScale = 2.0
        let measuredMagnitude = (rawShift.dx * rawShift.dx + rawShift.dy * rawShift.dy).squareRoot() / estScale
        let stimulusMagnitude = (Double(shiftX * shiftX) + Double(shiftY * shiftY)).squareRoot()
        #expect(abs(measuredMagnitude - stimulusMagnitude) <= 1.5)

        // Run the pinned smoother chain exactly as the decorator does (1080p plan → scale 1).
        var smoother = StabilizationSmoother()
        let correction = smoother.ingest(
            shift: StabilizationVector(dx: rawShift.dx / estScale, dy: rawShift.dy / estScale)
        )

        // Render A at rest and B with the produced correction: the contents must align.
        let renderedA = try await renderer.render(frameA, correction: .zero)
        let renderedBCorrected = try await renderer.render(frameB, correction: correction)
        let renderedBRaw = try await renderer.render(frameB, correction: .zero)

        let centroidA = lumaCentroid(of: renderedA.pixelBuffer)
        let corrected = lumaCentroid(of: renderedBCorrected.pixelBuffer)
        let uncorrected = lumaCentroid(of: renderedBRaw.pixelBuffer)

        // Stimulus validity: without correction the shift is plainly visible (~8.9 px).
        #expect(distance(uncorrected, centroidA) >= 5.0)
        // AC-6: with the correction applied, B lands back on A. A flipped sign would land
        // ~2Δ (≈18 px) away and fail this hard.
        #expect(distance(corrected, centroidA) <= 2.0)

        await renderer.finish()
    }

    @Test("AC-7: output buffers are pooled NV12/420v at PLANNED dimensions with verbatim PTS/hold")
    func outputFormat_nv12PlannedDimensionsVerbatimPts() async throws {
        let renderer = self.makeRenderer()
        try await renderer.prepare()

        let frame = makePatternFrame(offsetX: 0, offsetY: 0, ptsSeconds: 1.25, isHoldRepeat: true)
        let rendered = try await renderer.render(frame, correction: .zero)

        // NEW buffer from the stage's own pool — never the input reference.
        #expect(rendered.pixelBuffer !== frame.pixelBuffer)
        // NV12 video-range (the VTCompressionSession native format).
        #expect(
            CVPixelBufferGetPixelFormatType(rendered.pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        // Scale-back keeps the PLANNED dimensions (not the crop's).
        #expect(CVPixelBufferGetWidth(rendered.pixelBuffer) == planWidth)
        #expect(CVPixelBufferGetHeight(rendered.pixelBuffer) == planHeight)
        // Single-T0 invariant: PTS and the hold flag carry over verbatim.
        #expect(rendered.ptsHostTime == frame.ptsHostTime)
        #expect(rendered.isHoldRepeat == true)

        await renderer.finish()
    }
}
