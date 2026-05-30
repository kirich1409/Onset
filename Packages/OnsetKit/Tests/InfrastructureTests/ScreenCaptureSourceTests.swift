import CoreFoundation
import CoreMedia
import Domain
import Foundation
import ScreenCaptureKit
import Testing

@testable import Infrastructure

// MARK: - SCStreamConfiguration mapping tests

/// Tests for the pure `ScreenCaptureSource.makeStreamConfiguration` function.
///
/// These tests do NOT require a real display, TCC permission, or a live SCStream.
/// They verify the mapping from `(pixelWidth, pixelHeight, fps, displayMaxFPS)`
/// to the resulting `SCStreamConfiguration` properties.
@Suite("ScreenCaptureSource — SCStreamConfiguration mapping")
struct SCStreamConfigurationMappingTests {

    @Test("pixelFormat is 32BGRA (8-bit SDR)")
    func pixelFormatIs32BGRA() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 3456,
            pixelHeight: 2234,
            fps: 60,
            displayMaxFPS: 120
        )
        #expect(config.pixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test("queueDepth is 6")
    func queueDepthIs6() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 3456,
            pixelHeight: 2234,
            fps: 60,
            displayMaxFPS: 120
        )
        #expect(config.queueDepth == 6)
    }

    @Test("width and height match supplied pixel dimensions")
    func widthHeightMatchPixelDimensions() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 5120,
            pixelHeight: 2880,
            fps: 60,
            displayMaxFPS: 120
        )
        #expect(config.width == 5120)
        #expect(config.height == 2880)
    }

    @Test("fps is not clamped when below displayMaxFPS")
    func fpsNotClampedBelowMax() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 2560,
            pixelHeight: 1440,
            fps: 30,
            displayMaxFPS: 120
        )
        // minimumFrameInterval = CMTime(1, 30)
        let expected = CMTime(value: 1, timescale: 30)
        #expect(config.minimumFrameInterval == expected)
    }

    @Test("fps is clamped to displayMaxFPS when above it")
    func fpsClampedToDisplayMax() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 2560,
            pixelHeight: 1440,
            fps: 120,
            displayMaxFPS: 60
        )
        // Should clamp to 60, so minimumFrameInterval = CMTime(1, 60)
        let expected = CMTime(value: 1, timescale: 60)
        #expect(config.minimumFrameInterval == expected)
    }

    @Test("fps equal to displayMaxFPS is not clamped")
    func fpsEqualToMaxIsNotClamped() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 3456,
            pixelHeight: 2234,
            fps: 60,
            displayMaxFPS: 60
        )
        let expected = CMTime(value: 1, timescale: 60)
        #expect(config.minimumFrameInterval == expected)
    }

    @Test("captureResolution is .best")
    func captureResolutionIsBest() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 3456,
            pixelHeight: 2234,
            fps: 60,
            displayMaxFPS: 120
        )
        #expect(config.captureResolution == .best)
    }

    // MARK: Edge cases (J)

    @Test("fps = 0 is floored to 1 — interval is CMTime(1, 1)")
    func fpsZeroFlooredToOne() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 1920,
            pixelHeight: 1080,
            fps: 0,
            displayMaxFPS: 60
        )
        // max(1, min(0, 60)) = 1 → CMTime(value:1, timescale:1)
        let expected = CMTime(value: 1, timescale: 1)
        #expect(config.minimumFrameInterval == expected)
    }

    @Test("fps < 0 is floored to 1 — interval is CMTime(1, 1)")
    func fpsNegativeFlooredToOne() {
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 1920,
            pixelHeight: 1080,
            fps: -30,
            displayMaxFPS: 60
        )
        // max(1, min(-30, 60)) = 1 → CMTime(value:1, timescale:1)
        let expected = CMTime(value: 1, timescale: 1)
        #expect(config.minimumFrameInterval == expected)
    }

    @Test("fps one above displayMaxFPS is clamped to displayMaxFPS")
    func fpsOneAboveMaxIsClamped() {
        let displayMaxFPS = 120
        let config = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: 3456,
            pixelHeight: 2234,
            fps: displayMaxFPS + 1,
            displayMaxFPS: displayMaxFPS
        )
        // max(1, min(121, 120)) = 120 → CMTime(value:1, timescale:120)
        let expected = CMTime(value: 1, timescale: CMTimeScale(displayMaxFPS))
        #expect(config.minimumFrameInterval == expected)
    }
}

// MARK: - Test helpers for SCFrameStatus attachment

/// Shared helpers for creating `CMSampleBuffer`s with SCStreamFrameInfo status attachments.
///
/// ## Attachment mechanism
///
/// `CMSampleBufferGetSampleAttachmentsArray` returns *sample-level* attachments —
/// a `CFArray` of `CFMutableDictionary` (one dict per sample). This is the array
/// SCK populates with `SCStreamFrameInfo` entries. It is distinct from *buffer-level*
/// attachments set via `CMSetAttachment`.
///
/// To write into this array in tests:
/// 1. Create a buffer with `sampleCount: 1` (zero-sample buffers return nil from
///    `CMSampleBufferGetSampleAttachmentsArray` even with `createIfNecessary: true`).
/// 2. Call `CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: true)`.
/// 3. Cast the first element to `CFMutableDictionary` and write the key/value via
///    `CFDictionarySetValue` — the same dictionary that `shouldEmit` reads from.
///
/// The key is `SCStreamFrameInfo.status.rawValue as CFString`; the value is a
/// `CFNumber` holding the `SCFrameStatus.rawValue` (Int).
///
/// `shouldEmit` reads via `CFArrayGetValueAtIndex` → `CFDictionaryGetValue` → `CFNumberGetValue`,
/// which is the same CF path — so the round-trip is verified end-to-end.
private enum SampleBufferFactory {

    /// Creates a minimal `CMSampleBuffer` with a single logical sample but no
    /// pixel data, suitable for writing sample-level attachments.
    static func makeSingleSampleBuffer() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        // sampleCount: 1 is required for CMSampleBufferGetSampleAttachmentsArray to
        // return a non-nil array. With sampleCount: 0 the function returns nil even when
        // createIfNecessary is true.
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr, "CMSampleBufferCreate failed: \(status)")
        return try #require(sampleBuffer)
    }

    /// Creates a bare buffer with zero samples and no attachments (the conservative-skip
    /// input for `shouldEmit`).
    static func makeZeroSampleBuffer() throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        #expect(status == noErr, "CMSampleBufferCreate failed: \(status)")
        return try #require(sampleBuffer)
    }

    /// Creates a `CMSampleBuffer` with a sample-level `SCStreamFrameInfo.status`
    /// attachment set to `frameStatus`.
    ///
    /// The attachment is written directly into the sample-level attachments dictionary
    /// (the same dict that SCK populates, and that `shouldEmit` reads from) via
    /// `CFDictionarySetValue`. This exercises the full CF-level key/value round-trip.
    static func makeBuffer(withStatus frameStatus: SCFrameStatus) throws -> CMSampleBuffer {
        let buf = try makeSingleSampleBuffer()

        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                buf, createIfNecessary: true),
            CFArrayGetCount(attachmentsArray) > 0,
            let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0)
        else {
            Issue.record("Could not access sample-level attachments array")
            throw TestError.setupFailed
        }

        let dict = unsafeBitCast(rawDict, to: CFMutableDictionary.self)
        let key = SCStreamFrameInfo.status.rawValue as CFString
        let value = CFNumberCreate(kCFAllocatorDefault, .nsIntegerType, [frameStatus.rawValue])!

        // Write into the sample-level dict — same dictionary shouldEmit reads.
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passRetained(value).toOpaque()
        )

        return buf
    }

    enum TestError: Error { case setupFailed }
}

// MARK: - SCFrameStatus gate tests

/// Tests for the pure `ScreenCaptureSource.shouldEmit(_:)` function.
///
/// ## Attachment mechanism
///
/// See `SampleBufferFactory` for the write-side mechanism. `shouldEmit` reads via CF
/// (`CFArrayGetValueAtIndex`, `CFDictionaryGetValue`, `CFNumberGetValue`) — no Swift
/// bridge allocation on the hot path. The tests exercise the round-trip end-to-end.
///
/// ## L5 boundary
///
/// Full hold-time verification, zero-copy confirmation, 4K60 sustained capture, and
/// hardware-accelerated path all require a physical display + TCC permission + reference
/// hardware (MacBook Pro 14" M3 Max + external 4K60). Covered by `docs/spec/testing.md`
/// Appendix A; NOT automated in CI.
@Suite("ScreenCaptureSource — SCFrameStatus gate")
struct SCFrameStatusGateTests {

    @Test("Buffer with no SCStreamFrameInfo attachment is skipped (conservative)")
    func noAttachmentSkipped() throws {
        let buffer = try SampleBufferFactory.makeZeroSampleBuffer()
        // A zero-sample buffer has no sample-level attachments → shouldEmit returns false.
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }

    // MARK: shouldEmit behavioral tests (K)

    @Test("Buffer with status .complete is emitted")
    func completeStatusEmitted() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .complete)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == true)
    }

    @Test("Buffer with status .idle is skipped")
    func idleStatusSkipped() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .idle)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }

    @Test("Buffer with status .blank is skipped")
    func blankStatusSkipped() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .blank)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }

    @Test("Buffer with status .suspended is skipped")
    func suspendedStatusSkipped() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .suspended)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }

    @Test("Buffer with status .started is skipped")
    func startedStatusSkipped() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .started)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }

    @Test("Buffer with status .stopped is skipped")
    func stoppedStatusSkipped() throws {
        let buffer = try SampleBufferFactory.makeBuffer(withStatus: .stopped)
        #expect(ScreenCaptureSource.shouldEmit(buffer) == false)
    }
}

// MARK: - Emit-decision routing tests (L)

/// Tests for the full emit-decision path inside the SCStreamOutput callback.
///
/// `ScreenCaptureSource.shouldEmit(_:)` is a pure static function so the status-gate
/// decision (type guard + status check) can be tested without a live `SCStream`.
///
/// Tests exercise:
/// - A zero-sample buffer (no attachment): `shouldEmit` returns false — gate holds.
/// - A buffer with status `.complete`: `shouldEmit` returns true — gate passes.
///
/// End-to-end callback routing (SCStream → callback → sink dispatch) is an L5 concern
/// requiring TCC permission and real hardware.
@Suite("ScreenCaptureSource — emit decision routing")
struct EmitDecisionRoutingTests {

    @Test("shouldEmit returns false for a buffer with no attachment — routing gate holds")
    func bareBufferNotEmitted() throws {
        let buf = try SampleBufferFactory.makeZeroSampleBuffer()
        #expect(ScreenCaptureSource.shouldEmit(buf) == false)
    }

    @Test("shouldEmit returns true for a .complete buffer — routing gate passes")
    func completeBufferEmitted() throws {
        let buf = try SampleBufferFactory.makeBuffer(withStatus: .complete)
        #expect(ScreenCaptureSource.shouldEmit(buf) == true)
    }
}
