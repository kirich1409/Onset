import CoreMedia
import Domain
import Synchronization
import Testing

@testable import Application

// MARK: - Test-only fake writer

/// A fake `EncodingWriter` for `SampleRouter` unit tests.
///
/// Owns its own `Atomic<Bool>` for `isAlive` so tests can atomically flip a writer
/// dead and verify fan-out membership without locking or actor hops.
///
/// Named `FanoutFakeWriter` to avoid collision with the `FakeEncodingWriter` in
/// `ApplicationDITests.swift`, which uses a non-atomic `isAlive` suitable for DI
/// smoke tests but not for router concurrency assertions.
private final class FanoutFakeWriter: EncodingWriter, @unchecked Sendable {

    // MARK: - isAlive (atomic)

    // Atomic<Bool> is ~Copyable; stored as a let field and accessed via borrow.
    private let _alive = Atomic<Bool>(true)

    var isAlive: Bool { _alive.load(ordering: .acquiring) }

    /// Flips this writer dead via a release store — mirrors how a real pipeline writer
    /// signals shutdown without a lock.
    func markDead() {
        _alive.store(false, ordering: .releasing)
    }

    // MARK: - Append recording

    /// Buffers appended per track, keyed by `TrackKind`.  Read from the test thread
    /// after synchronous `receive` calls — no race because the router is nonisolated/sync.
    private(set) var appended: [TrackKind: [CMSampleBuffer]] = [:]

    func append(_ buf: CMSampleBuffer, track: TrackKind) {
        appended[track, default: []].append(buf)
    }

    // MARK: - Unused EncodingWriter requirements (no-op in tests)

    var health: WriterHealth = .alive
    func prepare(_ descriptor: OutputDescriptor) throws {}
    func beginSession(atSourceTime time: CMTime) {}
    func finalize() async throws {}
}

// MARK: - Helpers

/// Makes a minimal valid `CMSampleBuffer` suitable for identity comparisons.
/// The buffer carries no real media data — only the object identity matters in these tests.
private func makeSampleBuffer() throws -> CMSampleBuffer {
    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: nil,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let buf = sampleBuffer else {
        throw TestError.bufferCreationFailed(status)
    }
    return buf
}

private enum TestError: Error {
    case bufferCreationFailed(OSStatus)
}

// MARK: - SampleRouterTests

@Suite("SampleRouter")
struct SampleRouterTests {

    // MARK: - TC-9 (P0): Fan-out and per-source routing

    /// TC-9: Audio → both writers receive the IDENTICAL buffer object (bit-identity / AC-12).
    /// Video → only the matching writer, not the other.
    @Test("TC-9 audio fans out to both writers; video routes to its own writer only")
    func tc9FanOutAndVideoRouting() throws {
        let screenWriter = FanoutFakeWriter()
        let cameraWriter = FanoutFakeWriter()
        let router = SampleRouter(writers: [
            WriterBinding(writer: screenWriter, videoSource: .screen),
            WriterBinding(writer: cameraWriter, videoSource: .camera),
        ])

        // --- Audio fan-out: same CMSampleBuffer object reaches both writers ---
        let audioBuf = try makeSampleBuffer()
        router.receive(audioBuf, kind: .audio)

        let screenAudio = screenWriter.appended[.audio]
        let cameraAudio = cameraWriter.appended[.audio]
        #expect(screenAudio?.count == 1, "screen writer must receive the audio buffer")
        #expect(cameraAudio?.count == 1, "camera writer must receive the audio buffer")
        // Bit-identity: the SAME object, not a copy — AC-12 contract.
        #expect(screenAudio?.first === audioBuf, "screen writer must receive the identical audio CMSampleBuffer")
        #expect(cameraAudio?.first === audioBuf, "camera writer must receive the identical audio CMSampleBuffer")

        // --- Video (.screen) → only screen writer ---
        let screenBuf = try makeSampleBuffer()
        router.receive(screenBuf, kind: .screen)
        #expect(screenWriter.appended[.video]?.count == 1, "screen writer must receive the screen video buffer")
        #expect(cameraWriter.appended[.video] == nil, "camera writer must NOT receive a screen video buffer")

        // --- Video (.camera) → only camera writer ---
        let cameraBuf = try makeSampleBuffer()
        router.receive(cameraBuf, kind: .camera)
        #expect(cameraWriter.appended[.video]?.count == 1, "camera writer must receive the camera video buffer")
        // Screen writer still has only the one video buffer from above.
        #expect(
            screenWriter.appended[.video]?.count == 1,
            "screen writer must NOT receive an additional camera video buffer")
    }

    // MARK: - TC-10 (P1): Single-writer audio fan-out

    /// TC-10: When only one writer is wired (screen-only), audio fans into that single file.
    @Test("TC-10 audio routes into the single writer when only one binding is present")
    func tc10SingleWriterAudioFanOut() throws {
        let screenWriter = FanoutFakeWriter()
        let router = SampleRouter(writers: [
            WriterBinding(writer: screenWriter, videoSource: .screen)
        ])

        let audioBuf = try makeSampleBuffer()
        router.receive(audioBuf, kind: .audio)

        let appended = screenWriter.appended[.audio]
        #expect(appended?.count == 1, "the sole writer must receive the audio buffer")
        #expect(appended?.first === audioBuf, "must be the identical CMSampleBuffer object")

        // A .camera buffer with no camera binding is silently discarded (no crash, no routing).
        let cameraBuf = try makeSampleBuffer()
        router.receive(cameraBuf, kind: .camera)
        #expect(screenWriter.appended[.video] == nil, "no video should be appended — camera has no binding")
    }

    // MARK: - TC-25 (P0): Dead writer excluded from fan-out

    /// TC-25: After `markDead()`, the dead writer receives no further audio buffers.
    /// The alive writer continues to receive them uninterrupted.
    ///
    /// This test is deliberately non-async: `receive` is called synchronously from the
    /// test thread, proving that `SampleRouter.receive` is `nonisolated` and requires
    /// no actor hop or `await` — the hot-path contract from the architecture spec.
    @Test("TC-25 dead writer is excluded from audio fan-out; alive writer continues")
    func tc25DeadWriterExcludedFromFanOut() throws {
        let aliveWriter = FanoutFakeWriter()
        let deadWriter = FanoutFakeWriter()
        let router = SampleRouter(writers: [
            WriterBinding(writer: aliveWriter, videoSource: .screen),
            WriterBinding(writer: deadWriter, videoSource: .camera),
        ])

        // Pre-death: both writers should receive audio.
        let buf1 = try makeSampleBuffer()
        router.receive(buf1, kind: .audio)
        #expect(aliveWriter.appended[.audio]?.count == 1)
        #expect(deadWriter.appended[.audio]?.count == 1)

        // Kill one writer.
        deadWriter.markDead()

        // Post-death: only the alive writer receives audio.
        let buf2 = try makeSampleBuffer()
        router.receive(buf2, kind: .audio)
        #expect(aliveWriter.appended[.audio]?.count == 2, "alive writer must receive the second audio buffer")
        #expect(deadWriter.appended[.audio]?.count == 1, "dead writer must receive nothing after death")
    }

    // MARK: - Stats counters (control-plane reads)

    /// Verifies that per-source counters are incremented once per `receive` call
    /// (not once per fan-out writer), and are readable on the control plane.
    @Test("Per-source routed-sample counters increment once per receive call")
    func statsCountersIncrementPerReceiveCall() throws {
        let screenWriter = FanoutFakeWriter()
        let cameraWriter = FanoutFakeWriter()
        let router = SampleRouter(writers: [
            WriterBinding(writer: screenWriter, videoSource: .screen),
            WriterBinding(writer: cameraWriter, videoSource: .camera),
        ])

        // Initial state.
        #expect(router.screenReceivedCount == 0)
        #expect(router.cameraReceivedCount == 0)
        #expect(router.audioReceivedCount == 0)

        // Route some samples.
        router.receive(try makeSampleBuffer(), kind: .screen)
        router.receive(try makeSampleBuffer(), kind: .screen)
        router.receive(try makeSampleBuffer(), kind: .camera)
        router.receive(try makeSampleBuffer(), kind: .audio)
        router.receive(try makeSampleBuffer(), kind: .audio)
        router.receive(try makeSampleBuffer(), kind: .audio)

        // Audio counter is 3 (not 6 = 3 calls x 2 writers) — ingress tally, not fan-out tally.
        #expect(router.screenReceivedCount == 2)
        #expect(router.cameraReceivedCount == 1)
        #expect(router.audioReceivedCount == 3)
    }
}
