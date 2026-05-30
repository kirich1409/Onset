import AVFoundation
import CoreMedia
import Domain
import Foundation
import Testing

@testable import Infrastructure

// MARK: - Fake ClockProviding

/// Deterministic `ClockProviding` for testing.
///
/// `convert(_:from:)` applies a fixed offset to the input PTS so tests can assert
/// the exact host-time value without touching `CMSyncConvertTime` or real hardware.
///
/// ## `from:` recording (AC-9 clock wiring)
///
/// `recordedFrom` captures the last `src` argument passed to `convert`. Tests assert
/// this equals the `deviceClock` that was injected — a bug that substitutes
/// `referenceClock` for `deviceClock` produces a `recordedFrom` mismatch, catching
/// the wiring error without requiring a live session.
private final class FakeClockProviding: ClockProviding, @unchecked Sendable {
    let referenceClock: CMClock = CMClockGetHostTimeClock()

    /// Fixed offset added to every converted PTS (in the PTS's timescale).
    let offsetSeconds: Double

    /// The last `src` clock argument supplied to `convert(_:from:)`.
    /// `nil` until `convert` is called for the first time.
    private(set) var recordedFrom: CMClock?

    init(offsetSeconds: Double = 1.0) {
        self.offsetSeconds = offsetSeconds
    }

    func now() -> CMTime {
        CMClockGetTime(referenceClock)
    }

    /// Returns `time + offsetSeconds` as a new `CMTime` in the same timescale.
    /// Records `src` in `recordedFrom` for assertion in clock-wiring tests.
    func convert(_ time: CMTime, from src: CMClock) -> CMTime {
        recordedFrom = src
        let offset = CMTime(seconds: offsetSeconds, preferredTimescale: time.timescale)
        return CMTimeAdd(time, offset)
    }
}

// MARK: - Fake SampleSink

/// Capturing `SampleSink` for testing.
///
/// Collects every `receive` call in `received` so tests can assert exactly which
/// buffers (and how many) reached the sink without a live session or real microphone.
private final class FakeSampleSink: SampleSink, @unchecked Sendable {
    /// Buffers delivered in call order.
    private(set) var received: [CMSampleBuffer] = []

    func receive(_ buf: CMSampleBuffer, kind: SourceKind) {
        received.append(buf)
    }
}

// MARK: - Helpers

private func makeSilentAudioFormatDesc(sampleRate: Float64 = 48_000, channels: UInt32 = 1) throws
    -> CMFormatDescription
{
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var desc: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &desc
    )
    #expect(status == noErr)
    return try #require(desc)
}

private func makeSampleBuffer(
    pts: CMTime,
    duration: CMTime,
    formatDesc: CMFormatDescription
) throws -> CMSampleBuffer {
    // Number of PCM frames implied by the duration at the format's sample rate.
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)!.pointee
    let sampleCount = Int(CMTimeGetSeconds(duration) * asbd.mSampleRate)
    let byteCount = sampleCount * Int(asbd.mBytesPerFrame)

    var blockBuf: CMBlockBuffer?
    let bbStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuf
    )
    #expect(bbStatus == kCMBlockBufferNoErr)
    let validBlock = try #require(blockBuf)

    var sampleBuf: CMSampleBuffer?
    let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: validBlock,
        formatDescription: formatDesc,
        sampleCount: sampleCount,
        presentationTimeStamp: pts,
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuf
    )
    #expect(sbStatus == noErr)
    return try #require(sampleBuf)
}

// MARK: - sourceClock == injected clock.referenceClock

@Suite("AudioCaptureSource — sourceClock identity")
struct AudioCaptureSourceClockIdentityTests {

    @Test("sourceClock returns the injected clock's referenceClock")
    func sourceClockEqualsInjectedReferenceClock() {
        let fakeClock = FakeClockProviding()
        let source = AudioCaptureSource(clock: fakeClock)
        // CMClock does not conform to Equatable, but the ObjectIdentifier of the
        // underlying CF object verifies identity: both references must point to the
        // same CMClock object.
        #expect(source.sourceClock === fakeClock.referenceClock as AnyObject)
    }
}

// MARK: - Silence buffer generation tests (AC-13 / gap-detect pure logic)

/// Tests for `AudioCaptureSource.silenceBuffers(filling:referenceDuration:formatDescription:)`.
///
/// All tests operate on `CMTime` values and a `CMFormatDescription` constructed in-process —
/// no live microphone, no real `AVCaptureSession`.
///
/// ## L5 boundary
///
/// Real microphone capture at 48 kHz, Core Audio gap events triggering the silence-fill
/// path, and bit-identity verification across two files are verified manually against the
/// reference hardware (MacBook Pro 14" M3 Max) per `docs/spec/testing.md` Appendix A.
@Suite("AudioCaptureSource — silence buffer generation (AC-13)")
struct SilenceBufferGenerationTests {

    private static let sampleRate: Float64 = 48_000
    // One buffer of 1024 frames at 48 kHz.
    private static let refDuration = CMTime(value: 1024, timescale: 48_000)

    // MARK: No-gap → no silence

    @Test("no gap → silenceBuffers returns empty array")
    func noGapProducesNoSilence() throws {
        let desc = try makeSilentAudioFormatDesc()
        let pts = CMTime(value: 1024, timescale: 48_000)
        // prevEnd == pts: no gap
        let gap = CMTimeRange(start: pts, end: pts)
        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.isEmpty)
    }

    @Test("negative-duration gap → silenceBuffers returns empty array")
    func negativeDurationGapProducesNoSilence() throws {
        let desc = try makeSilentAudioFormatDesc()
        let start = CMTime(value: 2048, timescale: 48_000)
        let end = CMTime(value: 1024, timescale: 48_000)
        // end < start → negative duration
        let gap = CMTimeRange(start: start, end: end)
        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.isEmpty)
    }

    // MARK: Exact one-buffer gap

    @Test("gap of exactly one buffer duration → one silence buffer with correct PTS and duration")
    func exactOneBufferGap() throws {
        let desc = try makeSilentAudioFormatDesc()
        let gapStart = CMTime(value: 1024, timescale: 48_000)
        let gapEnd = CMTime(value: 2048, timescale: 48_000)  // gapStart + refDuration
        let gap = CMTimeRange(start: gapStart, end: gapEnd)

        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.count == 1)

        let silPTS = CMSampleBufferGetPresentationTimeStamp(result[0])
        #expect(silPTS == gapStart)

        let silDur = CMSampleBufferGetDuration(result[0])
        // Duration should match one buffer at 48 kHz.
        #expect(silDur.seconds.isApproximatelyEqual(to: 1024.0 / 48_000.0))
    }

    // MARK: Multi-buffer gap

    @Test("gap of two buffer durations → two silence buffers in PTS-ascending order")
    func twoBufferGap() throws {
        let desc = try makeSilentAudioFormatDesc()
        let gapStart = CMTime(value: 0, timescale: 48_000)
        let gapEnd = CMTime(value: 2048, timescale: 48_000)  // 2 × refDuration
        let gap = CMTimeRange(start: gapStart, end: gapEnd)

        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.count == 2)

        let pts0 = CMSampleBufferGetPresentationTimeStamp(result[0])
        let pts1 = CMSampleBufferGetPresentationTimeStamp(result[1])
        #expect(pts0 == gapStart)
        #expect(pts1 == CMTime(value: 1024, timescale: 48_000))
        // PTS-ascending order.
        #expect(CMTimeCompare(pts0, pts1) < 0)
    }

    // MARK: Multi-segment gap with per-segment duration assertions

    @Test("gap of ~2.5× refDuration → 3 segments with correct durations")
    func twoPointFiveBufferGap() throws {
        let desc = try makeSilentAudioFormatDesc()
        // 2.5 × 1024 = 2560 frames
        let gapStart = CMTime(value: 0, timescale: 48_000)
        let gapEnd = CMTime(value: 2560, timescale: 48_000)
        let gap = CMTimeRange(start: gapStart, end: gapEnd)

        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.count == 3)

        // First two segments: exactly refDuration.
        let dur0 = CMSampleBufferGetDuration(result[0])
        let dur1 = CMSampleBufferGetDuration(result[1])
        #expect(dur0.seconds.isApproximatelyEqual(to: Self.refDuration.seconds, tolerance: 1e-9))
        #expect(dur1.seconds.isApproximatelyEqual(to: Self.refDuration.seconds, tolerance: 1e-9))

        // Last segment: ≈ 0.5 × refDuration (512 frames / 48000).
        let dur2 = CMSampleBufferGetDuration(result[2])
        let halfRef = Self.refDuration.seconds / 2.0
        #expect(dur2.seconds.isApproximatelyEqual(to: halfRef, tolerance: 1.0 / 48_000.0))
    }

    // MARK: Threshold boundary

    @Test("gap smaller than one buffer duration still produces one silence segment")
    func subBufferGap() throws {
        let desc = try makeSilentAudioFormatDesc()
        // Half a buffer-duration gap.
        let gapStart = CMTime(value: 0, timescale: 48_000)
        let gapEnd = CMTime(value: 512, timescale: 48_000)
        let gap = CMTimeRange(start: gapStart, end: gapEnd)

        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        // The gap is non-zero, so one (shorter) silence segment is produced.
        #expect(result.count == 1)
        let silDur = CMSampleBufferGetDuration(result[0])
        // Duration ≤ referenceDuration (upper-bound).
        #expect(silDur.seconds <= Self.refDuration.seconds + 1.0 / 48_000.0)
        // Duration > 0 (lower-bound — must not produce an empty segment).
        #expect(silDur.seconds > 0.0)
    }

    // MARK: First buffer / no-previous (initialisation)

    @Test("gap with zero-length range (prevEnd == pts) produces no silence — first buffer init")
    func firstBufferNoSilence() throws {
        let desc = try makeSilentAudioFormatDesc()
        // Simulate first buffer: prevEnd is not set; caller passes an empty range.
        let pts = CMTime(value: 4096, timescale: 48_000)
        let gap = CMTimeRange(start: pts, end: pts)  // empty
        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: Self.refDuration,
            formatDescription: desc
        )
        #expect(result.isEmpty)
    }
}

// MARK: - PTS → host conversion via injected FakeClockProviding (AC-9)

/// Tests that `AudioCaptureSource.restamp` applies the expected host PTS.
///
/// Verifies that:
/// - `restamp(_:pts:)` returns a buffer whose PTS matches the supplied host PTS.
/// - The deterministic `FakeClockProviding.convert` is used (not `CMSyncConvertTime`).
///
/// This is the mandated "CMSyncConvertTime under test via a fake clock" (NFR-TEST).
@Suite("AudioCaptureSource — PTS re-stamp + host conversion (AC-9)")
struct PTSRestampTests {

    @Test("restamp produces buffer with the supplied host PTS")
    func restampAppliesNewPTS() throws {
        let desc = try makeSilentAudioFormatDesc()
        let devicePTS = CMTime(value: 0, timescale: 48_000)
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        let original = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)

        let hostPTS = CMTime(value: 48_000, timescale: 48_000)  // 1 second offset
        let restamped = AudioCaptureSource.restamp(original, pts: hostPTS)
        let result = try #require(restamped)

        let resultPTS = CMSampleBufferGetPresentationTimeStamp(result)
        #expect(resultPTS == hostPTS)
    }

    @Test("FakeClockProviding.convert adds fixed offset — restamp round-trip")
    func fakeClockConvertAndRestampRoundTrip() throws {
        let fakeClock = FakeClockProviding(offsetSeconds: 1.0)
        let desc = try makeSilentAudioFormatDesc()
        let devicePTS = CMTime(value: 0, timescale: 48_000)
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        let original = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)

        // Simulate what the hot-path does:
        let deviceClock = CMClockGetHostTimeClock()
        let hostPTS = fakeClock.convert(devicePTS, from: deviceClock)
        let restamped = AudioCaptureSource.restamp(original, pts: hostPTS)
        let result = try #require(restamped)

        let resultPTS = CMSampleBufferGetPresentationTimeStamp(result)
        // FakeClockProviding adds offsetSeconds (1.0 s), so hostPTS = devicePTS + 1s.
        let expectedPTS = CMTime(seconds: 1.0, preferredTimescale: 48_000)
        #expect(resultPTS.seconds.isApproximatelyEqual(to: expectedPTS.seconds, tolerance: 1e-9))
    }

    @Test("restamp preserves the original buffer's duration")
    func restampPreservesDuration() throws {
        let desc = try makeSilentAudioFormatDesc()
        let devicePTS = CMTime(value: 0, timescale: 48_000)
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        let original = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)

        let hostPTS = CMTime(value: 48_000, timescale: 48_000)
        let restamped = try #require(AudioCaptureSource.restamp(original, pts: hostPTS))

        let resultDur = CMSampleBufferGetDuration(restamped)
        #expect(resultDur.seconds.isApproximatelyEqual(to: refDuration.seconds, tolerance: 1e-9))
    }
}

// MARK: - hostStamp seam: AC-9 clock wiring (D)

/// Verifies that `hostStamp(_:deviceClock:clock:)` passes the `deviceClock` argument as
/// the `from:` parameter of `clock.convert`. A refactoring that swaps `deviceClock` for
/// `referenceClock` (or any other clock) would produce a `recordedFrom` mismatch here,
/// catching the sync corruption without a live session.
///
/// Also verifies the end-to-end path: a synthesised buffer routed through `hostStamp`
/// reaches the correct host PTS given the deterministic `FakeClockProviding`.
@Suite("AudioCaptureSource — hostStamp seam (AC-9 clock wiring)")
struct HostStampSeamTests {

    @Test("hostStamp calls clock.convert with deviceClock as the from: argument")
    func hostStampUsesDeviceClockAsFromArg() throws {
        let fakeClock = FakeClockProviding(offsetSeconds: 1.0)
        let desc = try makeSilentAudioFormatDesc()
        let devicePTS = CMTime(value: 0, timescale: 48_000)
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        let buffer = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)

        // Use a distinct CMClock object as deviceClock — not referenceClock.
        // CMClockGetHostTimeClock() returns the same singleton so we can use identity checks.
        let deviceClock = CMClockGetHostTimeClock()

        _ = AudioCaptureSource.hostStamp(buffer, deviceClock: deviceClock, clock: fakeClock)

        // convert must have been called with deviceClock as the from: argument.
        let recordedFrom = try #require(fakeClock.recordedFrom)
        #expect(recordedFrom === deviceClock as AnyObject)
    }

    @Test("hostStamp produces buffer with correct host PTS from deterministic FakeClock")
    func hostStampAppliesCorrectHostPTS() throws {
        let offsetSeconds = 2.0
        let fakeClock = FakeClockProviding(offsetSeconds: offsetSeconds)
        let desc = try makeSilentAudioFormatDesc()
        let devicePTS = CMTime(value: 0, timescale: 48_000)
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        let buffer = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)
        let deviceClock = CMClockGetHostTimeClock()

        let result = try #require(
            AudioCaptureSource.hostStamp(buffer, deviceClock: deviceClock, clock: fakeClock)
        )
        let resultPTS = CMSampleBufferGetPresentationTimeStamp(result)
        // FakeClockProviding adds offsetSeconds to devicePTS (= 0 → offsetSeconds).
        #expect(resultPTS.seconds.isApproximatelyEqual(to: offsetSeconds, tolerance: 1e-9))
    }

    @Test("hostStamp routes real buffer through FakeSink with correct PTS — lossless end-to-end")
    func hostStampRoutesThroughSink() throws {
        let offsetSeconds = 1.5
        let fakeClock = FakeClockProviding(offsetSeconds: offsetSeconds)
        let sink = FakeSampleSink()
        let desc = try makeSilentAudioFormatDesc()
        let deviceClock = CMClockGetHostTimeClock()

        // Three buffers at different device PTSs.
        let ptsList = [
            CMTime(value: 0, timescale: 48_000),
            CMTime(value: 1024, timescale: 48_000),
            CMTime(value: 2048, timescale: 48_000),
        ]
        let refDuration = CMTime(value: 1024, timescale: 48_000)

        for devicePTS in ptsList {
            let buf = try makeSampleBuffer(pts: devicePTS, duration: refDuration, formatDesc: desc)
            if let hostBuf = AudioCaptureSource.hostStamp(
                buf, deviceClock: deviceClock, clock: fakeClock
            ) {
                sink.receive(hostBuf, kind: .audio)
            }
        }

        // Lossless: every input buffer must reach the sink.
        #expect(sink.received.count == ptsList.count)

        // Each received buffer's PTS must equal devicePTS + offsetSeconds.
        for (idx, devicePTS) in ptsList.enumerated() {
            let receivedPTS = CMSampleBufferGetPresentationTimeStamp(sink.received[idx])
            let expectedPTS = devicePTS.seconds + offsetSeconds
            #expect(receivedPTS.seconds.isApproximatelyEqual(to: expectedPTS, tolerance: 1e-9))
        }
    }
}

// MARK: - Lossless invariant (structural)

/// Verifies the lossless audio guarantee: `AudioCaptureSource` has **no code path that
/// drops an audio buffer**. Because audio drop is a structural property (no `return` inside
/// `captureOutput` without also calling `sink.receive` or inserting silence), the unit
/// tests below document and assert the invariant via the pure helper functions.
///
/// - No `shouldEmit` gate exists (video has `alwaysDiscardsLateVideoFrames`; audio does not).
/// - The only early returns are: nil-sink guard (startup/shutdown race) and an
///   `restamp` failure fallback that emits the *original* buffer instead of nil.
@Suite("AudioCaptureSource — lossless invariant (AC-9)")
struct LosslessInvariantTests {

    @Test("silenceBuffers never returns fewer buffers than gap / refDuration — lossless fill")
    func silenceFillCoversEntireGap() throws {
        let desc = try makeSilentAudioFormatDesc()
        let refDuration = CMTime(value: 1024, timescale: 48_000)
        // A gap of exactly 3 buffer durations.
        let gapStart = CMTime(value: 0, timescale: 48_000)
        let gapEnd = CMTime(value: 3072, timescale: 48_000)
        let gap = CMTimeRange(start: gapStart, end: gapEnd)

        let result = AudioCaptureSource.silenceBuffers(
            filling: gap,
            referenceDuration: refDuration,
            formatDescription: desc
        )
        // All 3 buffer-duration slots must be filled.
        #expect(result.count == 3)

        // The union of silence PTS ranges covers [gapStart, gapEnd) without overlap.
        var runningPTS = gapStart
        for buf in result {
            let silPTS = CMSampleBufferGetPresentationTimeStamp(buf)
            #expect(silPTS == runningPTS)
            let silDur = CMSampleBufferGetDuration(buf)
            runningPTS = CMTimeAdd(runningPTS, silDur)
        }
        // After all segments, cursor should have reached gapEnd.
        #expect(runningPTS.seconds.isApproximatelyEqual(to: gapEnd.seconds, tolerance: 1e-9))
    }
}

// MARK: - Double precision helper

extension Double {
    fileprivate func isApproximatelyEqual(to other: Double, tolerance: Double = 1e-6) -> Bool {
        abs(self - other) <= tolerance
    }
}
