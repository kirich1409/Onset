import CoreMedia
import CoreVideo
@testable import Onset
import Testing
import VideoToolbox

// no_magic_numbers is disabled file-wide: these are Swift Testing structs (no XCTest
// parent class), so the rule's `test_parent_classes` exclusion in .swiftlint.yml does
// not apply; the numeric literals here are expected-value test data, not magic numbers.
// file_length is disabled: this single-concern test file covers L2 (mock) + L5 (live HW)
// encode paths plus their fixtures; splitting would scatter shared fixtures.
// type_body_length is disabled: the L2 suite intentionally collects every mock-path scenario
// (CFR, backpressure, lifecycle, fallback, anchored-PTS) in one struct so shared fixtures and
// the mock session live beside the cases that exercise them; splitting would scatter them.
// swiftlint:disable no_magic_numbers
// swiftlint:disable file_length
// swiftlint:disable type_body_length

// MARK: - Test fixtures

private let testFps = 30
private let testWidth: Int32 = 1280
private let testHeight: Int32 = 720

/// A fixed anchor so anchored-PTS assertions are deterministic.
/// Anchor at 100s on a 600-timescale host clock (typical CMClock timescale).
private func makeFixedAnchor() -> HostTimeAnchor {
    HostTimeAnchor(anchorTime: CMTime(value: 60000, timescale: 600))
}

/// Default settings used by the mock-session tests.
private func makeSettings() -> VTEncoderSettings {
    EncoderConfigBuilder.build(
        config: .mvpDefault,
        width: Int(testWidth),
        height: Int(testHeight),
        fps: testFps
    )
}

/// Builds a `VideoFrame` whose host-time PTS lands exactly on grid slot `slotIndex`
/// relative to `anchor` at `testFps`.
private func makeFrame(slotIndex: Int, anchor: HostTimeAnchor) -> VideoFrame {
    let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
    let slotSeconds = anchorSeconds + Double(slotIndex) / Double(testFps)
    let pts = CMTime(seconds: slotSeconds, preferredTimescale: 600)
    return VideoFrame(pixelBuffer: makePixelBuffer(), ptsHostTime: pts, isHoldRepeat: false)
}

/// Allocates a single IOSurface-backed pixel buffer (420v) for mock-path tests.
/// The mock never reads pixels; only the reference identity matters (hold assertion).
private func makePixelBuffer(width: Int = 16, height: Int = 16) -> CVPixelBuffer {
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

// MARK: - MockCompressionSession

/// A controllable `CompressionSession` for L2 tests.
///
/// Records every `encodeFrame` PTS and pixel-buffer reference; lets a test force a given
/// `pendingFrameCount` (backpressure) and a `kVTPropertyNotSupportedErr` for a chosen
/// property key (DataRateLimits fallback).
///
/// R1 — `appliedProperties`: every key that `setProperty` actually applied (i.e. was NOT in
/// `unsupportedKeys`) is stored here, keyed by the CFString as a String. Tests that assert
/// `configure()` applied its mandatory properties read this dict after `start()`.
///
/// R2 — `sink`: when set (by a test's inline factory), every successful `encodeFrame` call
/// echoes a minimal `CMSampleBuffer` carrying the passed PTS back through the sink so that
/// `encodedSamples` subscribers receive `EncodedSample` values. Existing tests leave `sink`
/// nil (the factory `{ _, _, _ in mock }` discards the sink param) — behaviour unchanged.
private final class MockCompressionSession: CompressionSession, @unchecked Sendable {
    /// PTS values handed to `encodeFrame`, in call order.
    private(set) var encodedPTS: [CMTime] = []
    /// Pixel-buffer references handed to `encodeFrame`, in call order (identity matters).
    private(set) var encodedBuffers: [CVPixelBuffer] = []
    /// Property keys whose `setProperty` should return `kVTPropertyNotSupportedErr`.
    var unsupportedKeys: Set<String> = []
    /// Properties that `setProperty` actually applied — keyed by the CFString cast to String.
    /// Populated only for keys that were NOT rejected via `unsupportedKeys`.
    private(set) var appliedProperties: [String: CFTypeRef] = [:]
    /// Fixed pending-frame count reported to the backpressure gate.
    var pending = 0
    /// Status returned by `encodeFrame`. Default `noErr`; set to a failure status to exercise
    /// the F2 encode-failure path (the frame is NOT recorded — mirrors a real session that
    /// emits no output for a rejected frame).
    var encodeStatus: OSStatus = noErr
    /// HW-encoder readback reported to the F6 start() guard. Default `true` so the routine L2
    /// tests start successfully; set `false` to exercise the HW-unavailable hard fail.
    var usingHardware = true
    /// Optional sink for the R2 PTS end-to-end assertion. When non-nil, a successful
    /// `encodeFrame` yields a minimal `CMSampleBuffer` (carrying `pts`) through the sink.
    /// Nil by default so the 15 existing tests are unaffected.
    var sink: EncodedSampleSink?

    nonisolated init() {}

    nonisolated func setProperty(key: CFString, value: CFTypeRef) -> OSStatus {
        if self.unsupportedKeys.contains(key as String) {
            return kVTPropertyNotSupportedErr
        }
        // R1: record every property that was successfully applied.
        self.appliedProperties[key as String] = value
        return noErr
    }

    nonisolated func encodeFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> OSStatus {
        // Record only what a real session would surface: on a non-noErr status the frame is
        // rejected and produces no output, so it must not appear in the recorded arrays.
        guard self.encodeStatus == noErr else { return self.encodeStatus }
        self.encodedPTS.append(pts)
        self.encodedBuffers.append(pixelBuffer)
        // R2: if a sink was wired, echo the PTS back via a minimal CMSampleBuffer so the
        // encoder's AsyncStream subscriber receives an EncodedSample with the anchored PTS.
        if let sink {
            if let buffer = makeSampleBuffer(pts: pts) {
                sink.yield(sampleBuffer: buffer)
            }
        }
        return noErr
    }

    nonisolated func pendingFrameCount() -> Int {
        self.pending
    }

    nonisolated func completeFrames() {}
    nonisolated func invalidate() {}
    nonisolated func usingHardwareEncoder() -> Bool {
        self.usingHardware
    }
}

/// Builds a minimal `CMSampleBuffer` carrying `pts` for the R2 PTS echo.
///
/// Uses a 16×16 HEVC format description and empty data so the buffer is valid without
/// requiring real compressed bytes. `CMSampleBufferGetPresentationTimeStamp` returns the
/// supplied `pts` unchanged — which is the only value the R2 assertion inspects.
private func makeSampleBuffer(pts: CMTime) -> CMSampleBuffer? {
    var formatDesc: CMVideoFormatDescription?
    let descStatus = CMVideoFormatDescriptionCreate(
        allocator: nil,
        codecType: kCMVideoCodecType_HEVC,
        width: 16,
        height: 16,
        extensions: nil,
        formatDescriptionOut: &formatDesc
    )
    guard descStatus == noErr, let formatDesc else { return nil }

    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(
        allocator: nil,
        dataBuffer: nil,
        formatDescription: formatDesc,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sample
    )
    guard status == noErr else { return nil }
    return sample
}

/// Convenience: build a `VideoEncoder` wired to a provided mock session.
@MainActor
private func makeEncoder(
    mock: MockCompressionSession,
    anchor: HostTimeAnchor,
    maxPendingFrames: Int = 4
)
-> VideoEncoder {
    VideoEncoder(
        settings: makeSettings(),
        width: testWidth,
        height: testHeight,
        fps: testFps,
        anchor: anchor,
        maxPendingFrames: maxPendingFrames,
        // selfClocked: false — L2 drives tick/clockTick/ingest synchronously; no wall-clock loop.
        selfClocked: false
    ) { _, _, _ in mock }
}

// MARK: - VideoEncoderTests (L2, mock session)

@Suite("VideoEncoder — L2 (mock session)")
struct VideoEncoderTests {
    // MARK: - CFR: snapped PTS on even cadence

    @Test("Even cadence frames → anchored PTS snapped on the grid for each slot")
    func evenCadence_snapsAnchoredPTS() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        for slot in 0..<4 {
            await encoder.ingest(makeFrame(slotIndex: slot, anchor: anchor))
        }

        #expect(mock.encodedPTS.count == 4)
        for slot in 0..<4 {
            let expected = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps)))
            #expect(CMTimeCompare(mock.encodedPTS[slot], expected) == 0)
        }
    }

    // MARK: - Anchored-PTS math pin

    @Test("Anchored PTS equals CMTimeAdd(anchor, slot/fps) exactly for adjacent slots")
    func anchoredPTS_exactInteger() async throws {
        // Adjacent slots 0..5: no catch-up holds, so encodedPTS[i] maps 1:1 to slotIndex i.
        // The purpose of this test is to pin the exact-integer CMTime reconstruction — not
        // catch-up contiguity (that is covered by catchUpContiguity and noGapInvariant below).
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        let slots = [0, 1, 2, 3, 4, 5]
        for slot in slots {
            await encoder.ingest(makeFrame(slotIndex: slot, anchor: anchor))
        }

        #expect(mock.encodedPTS.count == slots.count)
        for (index, slot) in slots.enumerated() {
            let expected = CMTimeAdd(
                anchor.anchorTime,
                CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps))
            )
            // Exact equality: integer rational CMTime math, no Double round-trip.
            #expect(CMTimeCompare(mock.encodedPTS[index], expected) == 0)
            // And the anchor is preserved (not bare-relative): the PTS is strictly after T0.
            #expect(CMTimeCompare(mock.encodedPTS[index], anchor.anchorTime) >= 0)
        }
    }

    // MARK: - CFR: hold re-submits last buffer

    @Test("Skipped slot tick → hold re-submits the LAST pixel buffer at the held slot PTS")
    func skippedSlot_holdReSubmitsLastBuffer() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        // Ingest slot 0 (a real frame), then tick slot 1 (no frame → hold).
        let frame0 = makeFrame(slotIndex: 0, anchor: anchor)
        await encoder.ingest(frame0)
        await encoder.tick(slotIndex: 1)

        #expect(mock.encodedBuffers.count == 2)
        // Hold re-submits the same pixel buffer reference as slot 0.
        #expect(mock.encodedBuffers[0] === mock.encodedBuffers[1])
        // The held PTS is the anchored PTS for slot 1.
        let expectedHoldPTS = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: 1, timescale: Int32(testFps)))
        #expect(CMTimeCompare(mock.encodedPTS[1], expectedHoldPTS) == 0)
    }

    @Test("Hold does NOT increment cfrNormalizationDrops")
    func hold_doesNotCountAsDrop() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        await encoder.tick(slotIndex: 1)

        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - Wall-clock clockTick()

    @Test("clockTick(nowSeconds:) fires exactly one hold when now is one-slot-plus-grace ahead of slot 0")
    func clockTick_holdsWhenSlotAhead() async throws {
        // Slot 1 is hold-eligible once: now >= anchor + 1.5/fps + grace
        // (eligibility boundary derived from catchUpHolds formula).
        // Pass now = boundary + 1ms → exactly one hold for slot 1.
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005 // matches encoder default
        // boundary = anchor + 1.5/fps + grace  (slot 1 becomes eligible)
        let boundary = anchorSeconds + 1.5 / Double(testFps) + grace
        let nowJustAfter = boundary + 0.001

        await encoder.clockTick(nowSeconds: nowJustAfter)

        // Exactly one hold emitted for slot 1.
        #expect(mock.encodedBuffers.count == 2)
        // Hold re-submits the same buffer reference as the real slot-0 frame.
        #expect(mock.encodedBuffers[0] === mock.encodedBuffers[1])
        let expectedHoldPTS = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: 1, timescale: Int32(testFps)))
        #expect(CMTimeCompare(mock.encodedPTS[1], expectedHoldPTS) == 0)
        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    @Test("clockTick(nowSeconds:) emits exactly cap=fps holds when now is far ahead, then continues on next call")
    func clockTick_farAheadEmitsCap() async throws {
        // Ingest slot 0, then call clockTick with a time far enough ahead to make
        // slots 1..testFps all eligible → exactly testFps holds (cap), cappedShort.
        // A second clockTick one more slot ahead emits exactly one more hold.
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005
        // Make slots 1 through testFps+1 all eligible by placing now well past their boundaries.
        let nowFarAhead = anchorSeconds + Double(testFps + 2) / Double(testFps) + grace + 0.001

        await encoder.clockTick(nowSeconds: nowFarAhead)

        // Cap = fps, so exactly testFps holds emitted (slots 1..testFps).
        #expect(mock.encodedBuffers.count == 1 + testFps)
        #expect(await encoder.cfrNormalizationDropCount == 0)

        // Second tick: slot testFps+1 is now eligible.
        // Eligibility boundary for slot N = anchor + (N + 0.5)/fps + grace.
        // For slot testFps+1 (=31 at fps=30): anchor + 31.5/30 + grace.
        let nowNextSlot = anchorSeconds + (Double(testFps + 1) + 0.5) / Double(testFps) + grace + 0.001
        await encoder.clockTick(nowSeconds: nowNextSlot)
        #expect(mock.encodedBuffers.count == 1 + testFps + 1)
    }

    @Test("clockTick is a no-op before any frame has been ingested")
    func clockTick_noOpBeforeFirstFrame() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.clockTick()

        #expect(mock.encodedBuffers.isEmpty)
        #expect(await encoder.cfrNormalizationDropCount == 0)
    }

    // MARK: - #102 regression: beat-race fix

    /// Regression: the old clock fired a hold for slot N at the start of N's window.
    /// The real frame for N (arriving a few ms later) was then dropped as a duplicate,
    /// degrading the camera file to a run of holds re-submitting stale content.
    ///
    /// The fix: `ingest` calls `catchUpThenEncode` which atomically claims the slot before
    /// the clock can touch it. `clockTick(nowSeconds:)` with now < slot-1's eligibility
    /// boundary must emit nothing; ingest of the real slot-1 frame must update
    /// `lastPixelBuffer`; the subsequent `clockTick` for slot 2 must re-submit the slot-1
    /// buffer (not the slot-0 buffer).
    @Test("#102 beat-race: pre-grace clock is no-op; real slot 1 wins; post-grace clock holds slot-1 buffer")
    func beatRaceRegression() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005

        // 1. Ingest real frame for slot 0.
        let frame0 = makeFrame(slotIndex: 0, anchor: anchor)
        await encoder.ingest(frame0)
        #expect(mock.encodedBuffers.count == 1)
        let buffer0 = mock.encodedBuffers[0]

        // 2. clockTick with now BEFORE slot 1's eligibility boundary → no emission.
        // boundary = anchor + 1.5/fps + grace
        let boundary1 = anchorSeconds + 1.5 / Double(testFps) + grace
        let nowJustBefore = boundary1 - 0.001
        await encoder.clockTick(nowSeconds: nowJustBefore)
        #expect(mock.encodedBuffers.count == 1) // no hold emitted

        // 3. Ingest real frame for slot 1 → must encode as real (not drop as duplicate).
        let frame1 = makeFrame(slotIndex: 1, anchor: anchor)
        await encoder.ingest(frame1)
        #expect(mock.encodedBuffers.count == 2)
        let buffer1 = mock.encodedBuffers[1]
        // buffer1 is a fresh allocation — distinct from buffer0.
        #expect(buffer1 !== buffer0)
        let expectedSlot1PTS = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: 1, timescale: Int32(testFps)))
        #expect(CMTimeCompare(mock.encodedPTS[1], expectedSlot1PTS) == 0)

        // 4. clockTick with now just past slot 2's eligibility boundary → one hold.
        // The hold must re-submit buffer1 (the fresh slot-1 content), NOT buffer0.
        let boundary2 = anchorSeconds + 2.5 / Double(testFps) + grace
        let nowAfterSlot2 = boundary2 + 0.001
        await encoder.clockTick(nowSeconds: nowAfterSlot2)
        #expect(mock.encodedBuffers.count == 3)
        #expect(mock.encodedBuffers[2] === buffer1)
        #expect(mock.encodedBuffers[2] !== buffer0)

        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - #102 regression: catch-up contiguity (ingest gap)

    @Test("Ingest slot 0 then slot 4 → holds 1,2,3 + real 4; encodedPTS strictly contiguous 0..4")
    func catchUpContiguity_ingestGap() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        let frame0 = makeFrame(slotIndex: 0, anchor: anchor)
        await encoder.ingest(frame0)
        let buffer0 = mock.encodedBuffers[0]

        let frame4 = makeFrame(slotIndex: 4, anchor: anchor)
        await encoder.ingest(frame4)

        // Total: slot 0 (real) + holds 1,2,3 + slot 4 (real) = 5 frames.
        #expect(mock.encodedBuffers.count == 5)

        // Holds (indices 1,2,3) re-submit buffer0.
        #expect(mock.encodedBuffers[1] === buffer0)
        #expect(mock.encodedBuffers[2] === buffer0)
        #expect(mock.encodedBuffers[3] === buffer0)

        // Real frame at index 4 is a different buffer.
        #expect(mock.encodedBuffers[4] !== buffer0)

        // PTS is strictly contiguous 0..4 with no gaps.
        for slot in 0...4 {
            let expected = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps)))
            #expect(CMTimeCompare(mock.encodedPTS[slot], expected) == 0)
        }

        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - #102 regression: clock catch-up contiguity

    @Test("Ingest slot 0, then clockTick far ahead → holds 1..6; encodedPTS contiguous; all buffer0")
    func clockCatchUpContiguity() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        let frame0 = makeFrame(slotIndex: 0, anchor: anchor)
        await encoder.ingest(frame0)
        let buffer0 = mock.encodedBuffers[0]

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005
        // Slot 6 is eligible when now >= anchor + 6.5/fps + grace.
        let nowAfterSlot6 = anchorSeconds + 6.5 / Double(testFps) + grace + 0.001
        await encoder.clockTick(nowSeconds: nowAfterSlot6)

        // 1 real + 6 holds = 7 total.
        #expect(mock.encodedBuffers.count == 7)

        // All holds re-submit buffer0.
        for idx in 1...6 {
            #expect(mock.encodedBuffers[idx] === buffer0)
        }

        // PTS contiguous 0..6.
        for slot in 0...6 {
            let expected = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps)))
            #expect(CMTimeCompare(mock.encodedPTS[slot], expected) == 0)
        }

        #expect(await encoder.cfrNormalizationDropCount == 0)
    }

    // MARK: - #102 regression: grace boundary (fps=30)

    @Test("Grace boundary: slot not eligible just before, eligible just after (fps=30)")
    func graceBoundary_fps30() async throws {
        // Verify the eligibility formula through the encoder driver at fps=30.
        // Slot 1: boundary = anchor + 1.5/30 + 0.005 = anchor + 0.055s.
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005
        let boundary = anchorSeconds + 1.5 / Double(testFps) + grace

        // Just before: no emission.
        await encoder.clockTick(nowSeconds: boundary - 0.0001)
        #expect(mock.encodedBuffers.count == 1)

        // Just after: exactly one hold.
        await encoder.clockTick(nowSeconds: boundary + 0.0001)
        #expect(mock.encodedBuffers.count == 2)
        let expectedPTS = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: 1, timescale: Int32(testFps)))
        #expect(CMTimeCompare(mock.encodedPTS[1], expectedPTS) == 0)
    }

    // MARK: - #102 regression: no-gap invariant

    @Test("Interleaved ingest/clockTick(nowSeconds:) produces no missing slots and strictly increasing PTS")
    func noGapInvariant() async throws {
        // Interleave real frames and clock ticks in a realistic pattern:
        // frame 0, clock tick (eligible for 1), frame 2, clock tick (eligible for 3,4), frame 5.
        // Expected emission order: 0(real), 1(hold), 2(real), 3(hold), 4(hold), 5(real).
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        let anchorSeconds = CMTimeGetSeconds(anchor.anchorTime)
        let grace = 0.005

        // Real frame slot 0.
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        // Clock tick: slot 1 just eligible.
        let after1 = anchorSeconds + 1.5 / Double(testFps) + grace + 0.001
        await encoder.clockTick(nowSeconds: after1)

        // Real frame slot 2.
        await encoder.ingest(makeFrame(slotIndex: 2, anchor: anchor))

        // Clock tick: slots 3 and 4 eligible.
        let after4 = anchorSeconds + 4.5 / Double(testFps) + grace + 0.001
        await encoder.clockTick(nowSeconds: after4)

        // Real frame slot 5.
        await encoder.ingest(makeFrame(slotIndex: 5, anchor: anchor))

        // Total: 6 frames (0..5), no gaps, strictly increasing PTS.
        #expect(mock.encodedPTS.count == 6)
        for slot in 0...5 {
            let expected = CMTimeAdd(anchor.anchorTime, CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps)))
            #expect(CMTimeCompare(mock.encodedPTS[slot], expected) == 0)
        }
        // Strictly increasing: each PTS > previous.
        for idx in 1..<mock.encodedPTS.count {
            #expect(CMTimeCompare(mock.encodedPTS[idx], mock.encodedPTS[idx - 1]) > 0)
        }

        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - CFR: duplicate frame into a filled slot

    @Test("Duplicate frame into a filled slot → cfrNormalizationDrops==1, backpressure untouched")
    func duplicateFrame_countsCfrDropOnly() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        // Two frames mapping to the SAME slot (0): first encodes, second is a duplicate.
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        #expect(mock.encodedPTS.count == 1)
        #expect(await encoder.cfrNormalizationDropCount == 1)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - Backpressure

    @Test("Session not ready (pending ≥ max) → encoderBackpressureDrops + DropEvent emitted")
    func backpressure_dropsAndEmitsEvent() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        mock.pending = 4 // == maxPendingFrames default
        let encoder = await makeEncoder(mock: mock, anchor: anchor, maxPendingFrames: 4)
        try await encoder.start()

        // Collect the first drop event.
        let dropTask = Task { () -> DropEvent? in
            for await event in await encoder.drops {
                return event
            }
            return nil
        }

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        await encoder.stop() // finishes the drops stream so the collector terminates

        #expect(mock.encodedPTS.isEmpty) // nothing reached the encoder
        #expect(await encoder.backpressureDropCount == 1)
        #expect(await encoder.cfrNormalizationDropCount == 0)

        let event = try #require(await dropTask.value)
        // Compare via switch rather than `==`: the InferIsolatedConformances trap makes
        // DropReason's Equatable conformance unusable from the nonisolated #expect context.
        if case .encoderBackpressureDrops = event.reason {} else {
            Issue.record("expected .encoderBackpressureDrops, got \(event.reason)")
        }
        #expect(event.count == 1)
    }

    // MARK: - DataRateLimits fallback

    @Test("DataRateLimits unsupported → start() proceeds AverageBitRate-only (no throw)")
    func dataRateLimitsUnsupported_fallsBack() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        mock.unsupportedKeys = [kVTCompressionPropertyKey_DataRateLimits as String]
        let encoder = await makeEncoder(mock: mock, anchor: anchor)

        // Must NOT throw — DataRateLimits failure is the documented graceful fallback.
        try await encoder.start()

        // The encoder is usable afterwards: a frame still encodes.
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        #expect(mock.encodedPTS.count == 1)
    }

    // MARK: - HW-unavailable hard fail (AC-6 / OpAC-4.1)

    @Test("Session factory throws → start() throws RecordingError.noHardwareEncoder")
    func hardwareUnavailable_throwsNoHardwareEncoder() async {
        let anchor = makeFixedAnchor()
        let encoder = VideoEncoder(
            settings: makeSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        ) { _, _, _ in throw VideoEncoderError.hardwareEncoderUnavailable }

        // Catch + switch rather than `#expect(throws: RecordingError.noHardwareEncoder)`
        // (value form): the InferIsolatedConformances trap makes RecordingError's Equatable
        // conformance unusable as the macro's `E: Equatable & Sendable` requirement.
        do {
            try await encoder.start()
            Issue.record("expected start() to throw .noHardwareEncoder")
        } catch let error as RecordingError {
            if case .noHardwareEncoder = error {} else {
                Issue.record("expected .noHardwareEncoder, got \(error)")
            }
        } catch {
            Issue.record("expected RecordingError, got \(error)")
        }
    }

    // MARK: - Mandatory property failure → encoderSetupFailed

    @Test("Mandatory property set failure → start() throws RecordingError.encoderSetupFailed")
    func mandatoryPropertyFailure_throwsEncoderSetupFailed() async {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        // ProfileLevel is mandatory (not the DataRateLimits fallback key).
        mock.unsupportedKeys = [kVTCompressionPropertyKey_ProfileLevel as String]
        let encoder = await makeEncoder(mock: mock, anchor: anchor)

        await #expect(throws: RecordingError.self) {
            try await encoder.start()
        }
    }

    // MARK: - F6: HW readback false → start() throws noHardwareEncoder

    @Test("Encoder reports Using==false → start() throws RecordingError.noHardwareEncoder")
    func usingHardwareFalse_throwsNoHardwareEncoder() async {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        mock.usingHardware = false // session created + configured, but NOT hardware-backed
        let encoder = await makeEncoder(mock: mock, anchor: anchor)

        do {
            try await encoder.start()
            Issue.record("expected start() to throw .noHardwareEncoder on Using==false")
        } catch let error as RecordingError {
            if case .noHardwareEncoder = error {} else {
                Issue.record("expected .noHardwareEncoder, got \(error)")
            }
        } catch {
            Issue.record("expected RecordingError, got \(error)")
        }
    }

    // MARK: - F1: failed start() finishes both streams (no hang)

    @Test("Failed start() finishes encodedSamples AND drops — a pre-start subscriber does not hang")
    func failedStart_finishesStreamsNoHang() async throws {
        let anchor = makeFixedAnchor()
        let encoder = VideoEncoder(
            settings: makeSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        ) { _, _, _ in throw VideoEncoderError.hardwareEncoderUnavailable }

        // Subscribe BEFORE start() — the hang would occur here if start() did not finish().
        let samplesDone = Task { () -> Bool in
            for await _ in await encoder.encodedSamples {}
            return true // stream terminated
        }
        let dropsDone = Task { () -> Bool in
            for await _ in await encoder.drops {}
            return true
        }

        // Force the HW-unavailable hard fail.
        do {
            try await encoder.start()
            Issue.record("expected start() to throw")
        } catch {
            // expected
        }

        // Both iterations must complete; bound the wait so a regression fails fast, not forever.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await samplesDone.value }
            group.addTask { await dropsDone.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5s deadline
                throw CancellationError()
            }
            // Two stream-drain results must arrive before the deadline task.
            _ = try await group.next()
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - F1: second start() throws (terminal)

    @Test("start() after a successful start()+stop() throws invalidLifecycleState")
    func secondStartAfterStop_throws() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)

        try await encoder.start()
        await encoder.stop()

        await #expect(throws: VideoEncoderError.self) {
            try await encoder.start()
        }
    }

    @Test("start() after a successful start() throws invalidLifecycleState (already running)")
    func secondStartWhileRunning_throws() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)

        try await encoder.start()

        await #expect(throws: VideoEncoderError.self) {
            try await encoder.start()
        }
        // The first session is still intact: ingest still encodes.
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        #expect(mock.encodedPTS.count == 1)
    }

    @Test("start() after a FAILED start() throws invalidLifecycleState (terminal)")
    func startAfterFailedStart_throws() async {
        let anchor = makeFixedAnchor()
        let encoder = VideoEncoder(
            settings: makeSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        ) { _, _, _ in throw VideoEncoderError.hardwareEncoderUnavailable }

        do {
            try await encoder.start()
            Issue.record("expected first start() to throw")
        } catch {
            // expected — first start fails
        }

        // A failed start is terminal: the second start() reports the lifecycle error, NOT
        // another factory attempt.
        await #expect(throws: VideoEncoderError.self) {
            try await encoder.start()
        }
    }

    // MARK: - F2: encodeFrame failure → logged, no counter bump, gap reflected

    @Test("encodeFrame failure → no drop counters bumped, encoded count reflects the missing frame")
    func encodeFrameFailure_documentedCurrentBehavior() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        mock.encodeStatus = kVTParameterErr // a non-noErr encode status
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))

        // Documented current behavior (F2): logged only. The frame is an invisible gap —
        // it never reaches the encoded arrays, and NEITHER drop counter moves (OpAC-4.3/4.4
        // separation intact).
        #expect(mock.encodedPTS.isEmpty)
        #expect(await encoder.cfrNormalizationDropCount == 0)
        #expect(await encoder.backpressureDropCount == 0)
    }

    // MARK: - R1: configure() applies mandatory HEVC properties to the session

    @Test("configure() applies mandatory HEVC properties to the session")
    func configure_appliesMandatoryHEVCProperties() async throws {
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()
        let encoder = await makeEncoder(mock: mock, anchor: anchor)
        try await encoder.start()

        // All five mandatory properties must have been applied to the session.
        // CFEqual avoids CFBoolean / CFNumber cast requirements; it is type-safe at CFTypeRef.
        let props = mock.appliedProperties

        let realTime = try #require(
            props[kVTCompressionPropertyKey_RealTime as String],
            "RealTime must be applied to the session"
        )
        #expect(CFEqual(realTime, kCFBooleanTrue), "RealTime must be true (real-time encode)")

        let allowReorder = try #require(
            props[kVTCompressionPropertyKey_AllowFrameReordering as String],
            "AllowFrameReordering must be applied to the session"
        )
        #expect(CFEqual(allowReorder, kCFBooleanTrue), "AllowFrameReordering must be true (B-frames)")

        let profileLevel = try #require(
            props[kVTCompressionPropertyKey_ProfileLevel as String],
            "ProfileLevel must be applied to the session"
        )
        // Assert the literal VT constant so a change in settings default is caught early.
        #expect(
            CFEqual(profileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
            "ProfileLevel must be HEVC Main AutoLevel"
        )

        let settings = makeSettings()

        let averageBitRate = try #require(
            props[kVTCompressionPropertyKey_AverageBitRate as String],
            "AverageBitRate must be applied to the session"
        )
        #expect(
            CFEqual(averageBitRate, settings.averageBitRate as CFNumber),
            "AverageBitRate must match the resolved settings value"
        )

        let maxKFI = try #require(
            props[kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String],
            "MaxKeyFrameIntervalDuration must be applied to the session"
        )
        #expect(
            CFEqual(maxKFI, settings.maxKeyFrameIntervalDurationSeconds as CFNumber),
            "MaxKeyFrameIntervalDuration must match the resolved settings value"
        )
    }

    // MARK: - R2: emitted EncodedSample carries the anchored PTS end-to-end

    @Test("EncodedSample.ptsHostTime carries the anchored PTS from encodeFrame to the subscriber")
    func emittedSample_ptsHostTimeAnchored() async throws {
        // L2 deterministic path: the mock echoes the PTS through the sink so the production
        // EncodedSampleSink.yield → CMSampleBufferGetPresentationTimeStamp → continuation chain
        // is exercised without hardware. Pins that configure+submit sets the PTS on the sample
        // the consumer sees, not just on the buffer handed to encodeFrame.
        let anchor = makeFixedAnchor()
        let mock = MockCompressionSession()

        // Inline factory: captures `mock` AND wires the sink so the mock can echo samples.
        let encoder = await VideoEncoder(
            settings: makeSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        ) { _, _, sink in
            mock.sink = sink
            return mock
        }

        try await encoder.start()

        // Subscribe before ingesting — the sample arrives asynchronously through the continuation.
        let collector = Task { () -> EncodedSample? in
            for await sample in await encoder.encodedSamples {
                return sample // bounded: return on first sample
            }
            return nil
        }

        // Ingest slot 0: anchored PTS == anchor.anchorTime (slot 0 offset is zero).
        await encoder.ingest(makeFrame(slotIndex: 0, anchor: anchor))
        // stop() drains pending frames and finishes the stream so the collector terminates.
        await encoder.stop()

        let sample = try #require(await collector.value, "expected at least one EncodedSample")
        // Slot 0: CMTimeAdd(anchor, 0/fps) == anchor.
        let expectedPTS = anchor.anchorTime
        #expect(
            CMTimeCompare(sample.ptsHostTime, expectedPTS) == 0,
            "EncodedSample.ptsHostTime must equal the anchored slot-0 PTS"
        )
    }
}

// MARK: - L5 opt-in condition

/// Returns `true` when the L5 live-encode test should run.
///
/// Gated on `ONSET_RUN_L5_ENCODE=1` (explicit opt-in). Unlike the camera L5 path there is
/// no TCC requirement — encoding a synthetic buffer needs no device permission. Used as the
/// `.enabled(if:)` trait so a non-opted-in run reports as a genuine SKIP, not a false PASS.
private func l5EncodeEnabled() -> Bool {
    ProcessInfo.processInfo.environment["ONSET_RUN_L5_ENCODE"] == "1"
}

/// Fills a fresh IOSurface-backed 420v pixel buffer with a deterministic gradient.
private func makeGradientPixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let buffer = makePixelBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    // Luma plane (0): horizontal gradient. Chroma plane (1): mid-grey.
    if let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let ptr = lumaBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<lumaHeight {
            for col in 0..<lumaWidth {
                ptr[row * bytesPerRow + col] = UInt8((col * 255) / max(lumaWidth, 1))
            }
        }
    }
    if let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let ptr = chromaBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<chromaHeight {
            for col in 0..<bytesPerRow {
                ptr[row * bytesPerRow + col] = 128
            }
        }
    }
    return buffer
}

// MARK: - VideoEncoderLiveTests (L5, real VTCompressionSession)

@Suite("VideoEncoder — L5 live hardware encode", .serialized, .timeLimit(.minutes(1)))
struct VideoEncoderLiveTests {
    @Test(
        "real HW HEVC session encodes a synthetic gradient → first sample is a keyframe",
        .enabled(if: l5EncodeEnabled())
    )
    func liveEncode_producesKeyframeFirst() async throws {
        let anchor = makeFixedAnchor()
        // Default factory → real LiveCompressionSession (HW-required HEVC).
        // selfClocked: false — drive ingest manually; the wall-clock loop would add
        // nondeterministic huge-slot holds with the fixed past anchor.
        let encoder = VideoEncoder(
            settings: makeSettings(),
            width: testWidth,
            height: testHeight,
            fps: testFps,
            anchor: anchor,
            selfClocked: false
        )
        try await encoder.start()

        // Collect the first emitted encoded sample.
        let collector = Task { () -> EncodedSample? in
            for await sample in await encoder.encodedSamples {
                return sample
            }
            return nil
        }

        // Feed a handful of synthetic gradient frames on the grid.
        for slot in 0..<10 {
            let slotOffset = CMTimeMake(value: CMTimeValue(slot), timescale: Int32(testFps))
            let frame = VideoFrame(
                pixelBuffer: makeGradientPixelBuffer(width: Int(testWidth), height: Int(testHeight)),
                ptsHostTime: CMTimeAdd(anchor.anchorTime, slotOffset),
                isHoldRepeat: false
            )
            await encoder.ingest(frame)
        }

        // Assert the live session used the hardware encoder.
        #expect(await encoder.isUsingHardwareEncoder == true)

        await encoder.stop() // drains pending frames, then finishes the stream

        let first = await collector.value
        let sample = try #require(first, "expected at least one encoded HEVC sample")
        #expect(sample.isKeyframe == true)
    }
}

// swiftlint:enable no_magic_numbers
// swiftlint:enable type_body_length
// file_length stays disabled through EOF: it is a whole-file rule, so re-enabling it before the
// last line would re-trigger on the total count. The file intentionally collects L2 + L5 paths.
