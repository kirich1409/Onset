// StabilizingVideoSourceTests.swift
// OnsetTests
//
// L2 suites for the StabilizingVideoSource actor decorator (#297): dual-facet forwarding,
// drop merge + attribution (AC-4), warm-up / estScale choice, correction sign at the
// orchestration level, freeze, bypass (both triggers' plumbing), one-shot lifecycle, and the
// failed-start teardown order (fake pattern: RecordingSessionTests fakes).
//
// The fake stage occupies its own serial work queue SYNCHRONOUSLY via a DispatchSemaphore when
// asked to block (never Task.sleep) — mirroring the live renderer's isolation shape so the
// eager-drain attribution invariant is exercised for real.
//
// swiftlint:disable file_length

import CoreMedia
import CoreVideo
import Foundation
@testable import Onset
import os
import Testing

// MARK: - Frame factory

/// Allocates a tiny 420v pixel buffer; only reference identity matters in these tests.
private func makePixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        preconditionFailure("pixel buffer alloc failed: \(status)")
    }
    return buffer
}

/// Builds a frame with the given absolute host-time seconds.
private func makeFrame(atSeconds seconds: Double) -> VideoFrame {
    VideoFrame(
        pixelBuffer: makePixelBuffer(),
        ptsHostTime: CMTime(seconds: seconds, preferredTimescale: 600),
        isHoldRepeat: false
    )
}

/// Polls a condition with a bounded timeout (pattern: RecordingCoordinatorTests.eventuallyMain).
private func eventually(timeoutMs: Int = 8000, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
    }
    return condition()
}

// MARK: - Fake wrapped camera

/// A fake record camera (both facets, one object) with emission hooks — the same shape as
/// `FakeCameraSource` in RecordingSessionTests.
private final class FakeWrappedCamera: VideoFrameSource, AudioSampleSource, @unchecked Sendable {
    nonisolated let frames: AsyncStream<VideoFrame>
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    nonisolated let audioSamples: AsyncStream<AudioSample>
    private let audioContinuation: AsyncStream<AudioSample>.Continuation
    nonisolated let events: AsyncStream<SourceEvent>
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    private let state = OSAllocatedUnfairLock(initialState: (startCalls: 0, stopCalls: 0))

    /// When set, `start(anchoredTo:)` throws this — drives the wrapped-failure teardown path.
    let startError = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)

    var startCalls: Int { self.state.withLock(\.startCalls) }
    var stopCalls: Int { self.state.withLock(\.stopCalls) }

    init() {
        let (frames, framesContinuation) = AsyncStream.makeStream(of: VideoFrame.self)
        self.frames = frames
        self.framesContinuation = framesContinuation
        let (audio, audioContinuation) = AsyncStream.makeStream(of: AudioSample.self)
        self.audioSamples = audio
        self.audioContinuation = audioContinuation
        let (events, eventsContinuation) = AsyncStream.makeStream(of: SourceEvent.self)
        self.events = events
        self.eventsContinuation = eventsContinuation
        let (drops, dropsContinuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = drops
        self.dropsContinuation = dropsContinuation
    }

    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        self.state.withLock { $0.startCalls += 1 }
        if let error = self.startError.withLock({ $0 }) { throw error }
    }

    func stop() async {
        self.state.withLock { $0.stopCalls += 1 }
        self.framesContinuation.finish()
        self.audioContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }

    func emitFrame(_ frame: VideoFrame) {
        self.framesContinuation.yield(frame)
    }

    func emitEvent(_ event: SourceEvent) {
        self.eventsContinuation.yield(event)
    }

    func emitDrop(_ event: DropEvent) {
        self.dropsContinuation.yield(event)
    }
}

// MARK: - Fake stage

/// A scripted `StabilizationStage`: records every call, scripts estimation results and render
/// errors, and can SYNCHRONOUSLY occupy its serial work queue via a semaphore (the "slow Vision"
/// simulation the attribution test needs).
private final class FakeStage: StabilizationStage, @unchecked Sendable {
    struct State {
        var prepareCalls = 0
        var prepareError: (any Error)?
        var activatedScales: [Int] = []
        var activationError: (any Error)?
        /// FIFO of scripted estimation results; empty → `.success(defaultShift)`.
        var estimateScript: [Result<StabilizationVector?, any Error>] = []
        var defaultShift: StabilizationVector?
        var estimateCalls = 0
        var renderCorrections: [StabilizationVector] = []
        var renderError: (any Error)?
        var renderCalls = 0
        var deactivateCalls = 0
        var finishCalls = 0
        /// When `true`, each render blocks the work queue on `gate` until signalled.
        var blockRender = false
        /// Number of renders currently or ever parked on the gate (entry counter).
        var blockedRenderEntries = 0
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    /// The fake's own serial work queue — mirrors the live renderer's isolation shape.
    private let workQueue = DispatchQueue(label: "OnsetTests.FakeStage.work")

    /// Blocked renders park on this semaphore (synchronous queue occupation, not Task.sleep).
    let gate = DispatchSemaphore(value: 0)

    func prepare() async throws {
        let error = self.state.withLock { state -> (any Error)? in
            state.prepareCalls += 1
            return state.prepareError
        }
        if let error { throw error }
    }

    func activateEstimation(estScale: Int) async throws {
        let error = self.state.withLock { state -> (any Error)? in
            state.activatedScales.append(estScale)
            return state.activationError
        }
        if let error { throw error }
    }

    func estimateShift(of frame: VideoFrame) async throws -> StabilizationVector? {
        let result: Result<StabilizationVector?, any Error> = self.state.withLock { state in
            state.estimateCalls += 1
            if !state.estimateScript.isEmpty { return state.estimateScript.removeFirst() }
            return .success(state.defaultShift)
        }
        return try result.get()
    }

    func render(_ frame: VideoFrame, correction: StabilizationVector) async throws -> VideoFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VideoFrame, any Error>) in
            self.workQueue.async {
                let shouldBlock = self.state.withLock { state -> Bool in
                    if state.blockRender { state.blockedRenderEntries += 1 }
                    return state.blockRender
                }
                if shouldBlock {
                    // Synchronously occupies the serial work queue — exactly how a live Vision
                    // latency outlier stalls the stage while the drain keeps running.
                    self.gate.wait()
                }
                let error = self.state.withLock { state -> (any Error)? in
                    state.renderCalls += 1
                    state.renderCorrections.append(correction)
                    return state.renderError
                }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // Passthrough: pts / isHoldRepeat preserved by identity (the live renderer's
                    // new-buffer contract is covered by StabilizationSignTests on real GPU).
                    continuation.resume(returning: frame)
                }
            }
        }
    }

    func deactivateEstimation() async {
        self.state.withLock { $0.deactivateCalls += 1 }
    }

    func finish() async {
        self.state.withLock { $0.finishCalls += 1 }
    }
}

// MARK: - Collectors

/// Collects stream elements across isolations for polling assertions.
private final class FrameLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [VideoFrame]())
    var frames: [VideoFrame] { self.lock.withLock { $0 } }
    var count: Int { self.lock.withLock(\.count) }
    func append(_ frame: VideoFrame) { self.lock.withLock { $0.append(frame) } }
}

/// Collects drop events across isolations for polling assertions.
private final class DropLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [DropEvent]())
    var events: [DropEvent] { self.lock.withLock { $0 } }
    var count: Int { self.lock.withLock(\.count) }
    func append(_ event: DropEvent) { self.lock.withLock { $0.append(event) } }
}

// MARK: - SUT factory

/// Builds the decorator + fakes with a canonical 1080p plan geometry.
private func makeSUT(
    warmUpFrameCount: Int = 1,
    consecutiveErrorLimit: Int = StabilizationTuning.consecutiveErrorLimit,
    overloadDetector: StabilizationOverloadDetector = StabilizationOverloadDetector()
)
-> (sut: StabilizingVideoSource, camera: FakeWrappedCamera, stage: FakeStage) {
    let camera = FakeWrappedCamera()
    let stage = FakeStage()
    let plan = CapabilityResolver.makeStabilizationPlan(planWidth: 1920, planHeight: 1080)
    let sut = StabilizingVideoSource(
        wrapping: camera,
        stabilization: plan,
        planWidth: 1920,
        stage: stage,
        warmUpFrameCount: warmUpFrameCount,
        consecutiveErrorLimit: consecutiveErrorLimit,
        overloadDetector: overloadDetector
    )
    return (sut, camera, stage)
}

/// Spawns a consumer task collecting the decorator's output frames.
private func consumeFrames(_ sut: StabilizingVideoSource, into log: FrameLog) -> Task<Void, Never> {
    let stream = sut.frames
    return Task {
        for await frame in stream {
            log.append(frame)
        }
    }
}

/// Spawns a consumer task collecting the decorator's merged drops.
private func consumeDrops(_ sut: StabilizingVideoSource, into log: DropLog) -> Task<Void, Never> {
    let stream = sut.drops
    return Task {
        for await event in stream {
            log.append(event)
        }
    }
}

// MARK: - Lifecycle & teardown

@Suite("StabilizingVideoSource — lifecycle & failed-start teardown")
struct StabilizingVideoSourceLifecycleTests {
    @Test("Stage prepare failure: wrapped camera never starts; error is captureSetupFailed with StabilizationError inner")
    func prepareFailure_teardownOrder() async {
        let (sut, camera, stage) = makeSUT()
        stage.state.withLock { $0.prepareError = StabilizationError.metalUnavailable }

        do {
            try await sut.start(anchoredTo: HostTimeAnchor.now())
            Issue.record("start must throw when stage.prepare fails")
        } catch let RecordingError.captureSetupFailed(inner) {
            // The DISTINCT inner type is the alert's attribution contract (AC-5).
            #expect(inner is StabilizationError)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        // No side effects: the camera was never touched.
        #expect(camera.startCalls == 0)
        #expect(camera.stopCalls == 0)
    }

    @Test("Wrapped start failure: stage resources released; the camera's own error passes UNCHANGED")
    func wrappedFailure_stageReleased_errorUnchanged() async {
        let (sut, camera, stage) = makeSUT()
        camera.startError.withLock { $0 = RecordingError.captureSetupFailed(CameraSourceError.deviceNotFound) }

        do {
            try await sut.start(anchoredTo: HostTimeAnchor.now())
            Issue.record("start must rethrow the wrapped source's error")
        } catch let RecordingError.captureSetupFailed(inner) {
            // A real camera failure must NOT be re-attributed to stabilization.
            #expect(!(inner is StabilizationError))
            #expect(inner is CameraSourceError)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(stage.state.withLock(\.finishCalls) == 1)
    }

    @Test("start is one-shot: a second call is ignored")
    func start_isOneShot() async throws {
        let (sut, camera, _) = makeSUT()
        try await sut.start(anchoredTo: HostTimeAnchor.now())
        try await sut.start(anchoredTo: HostTimeAnchor.now())
        #expect(camera.startCalls == 1)
        await sut.stop()
    }

    @Test("Graceful stop joins in order and is idempotent; streams finish; stage released")
    func stop_gracefulAndIdempotent() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 10)
        let frameLog = FrameLog()
        let dropLog = DropLog()
        let framesTask = consumeFrames(sut, into: frameLog)
        let dropsTask = consumeDrops(sut, into: dropLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        camera.emitFrame(makeFrame(atSeconds: 100.00))
        camera.emitFrame(makeFrame(atSeconds: 100.05))
        #expect(await eventually { frameLog.count == 2 })

        await sut.stop()
        await sut.stop() // idempotent second call

        // Consumer loops end because the decorator's streams finished.
        await framesTask.value
        await dropsTask.value
        #expect(camera.stopCalls >= 1)
        #expect(stage.state.withLock(\.finishCalls) == 1)
        // Both frames survived the graceful stop (no tail loss).
        #expect(frameLog.count == 2)
    }
}

// MARK: - Forwarding & warm-up

@Suite("StabilizingVideoSource — forwarding, warm-up, correction")
struct StabilizingVideoSourceProcessingTests {
    @Test("audioSamples and events forward the wrapped source's streams (dual facet)")
    func audioAndEvents_forwardToWrapped() async throws {
        let (sut, camera, _) = makeSUT(warmUpFrameCount: 10)
        let eventsStream = sut.events

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        let collector = Task { () -> SourceEvent? in
            for await event in eventsStream {
                return event
            }
            return nil
        }
        camera.emitEvent(.cameraDisconnected)
        let received = await collector.value
        #expect(received == .cameraDisconnected)
        await sut.stop()
    }

    @Test("Warm-up frames render with zero correction and no estimation calls")
    func warmUp_zeroCorrection_noEstimation() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 3)
        let frameLog = FrameLog()
        let framesTask = consumeFrames(sut, into: frameLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        for index in 0..<3 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.05))
        }
        #expect(await eventually { frameLog.count == 3 })
        #expect(stage.state.withLock(\.estimateCalls) == 0)
        #expect(stage.state.withLock { $0.renderCorrections.allSatisfy { $0 == .zero } })

        await sut.stop()
        await framesTask.value
    }

    @Test("Slow cadence (50 ms) activates estimation at 3×; fast cadence (20 ms) at 2×")
    func estScaleChoice_followsMeasuredCadence() async throws {
        for (intervalSeconds, expectedScale) in [(0.050, 3), (0.020, 2)] {
            let (sut, camera, stage) = makeSUT(warmUpFrameCount: 4)
            let frameLog = FrameLog()
            let framesTask = consumeFrames(sut, into: frameLog)

            try await sut.start(anchoredTo: HostTimeAnchor.now())
            // 4 warm-up frames + 1 stabilized frame (activation happens on the latter).
            for index in 0..<5 {
                camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * intervalSeconds))
            }
            #expect(await eventually { frameLog.count == 5 })
            #expect(stage.state.withLock(\.activatedScales) == [expectedScale])

            await sut.stop()
            await framesTask.value
        }
    }

    @Test("Correction equals −shift scaled by estScale and plan width (orchestration-level sign)")
    func correction_negatedScaledShift() async throws {
        // Warm-up of 2 frames at 20 ms spacing (median < 40 ms) chooses the LOW scale (2×):
        // raw shifts are divided by 2 before the smoother.
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 2)
        stage.state.withLock {
            $0.estimateScript = [
                .success(nil), // first stabilized frame: no pair yet
                .success(StabilizationVector(dx: 6.0, dy: -2.0)), // raw, estimation coords
            ]
        }
        let frameLog = FrameLog()
        let framesTask = consumeFrames(sut, into: frameLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        for index in 0..<4 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.020))
        }
        #expect(await eventually { frameLog.count == 4 })
        #expect(stage.state.withLock(\.activatedScales) == [2])

        let corrections = stage.state.withLock(\.renderCorrections)
        try #require(corrections.count == 4)
        // Frames 1–2 (warm-up) and frame 3 (no pair yet): zero correction.
        #expect(corrections[0] == .zero)
        #expect(corrections[1] == .zero)
        #expect(corrections[2] == .zero)
        // Frame 4: shiftEq = raw/2 = (3, −1); correction ≈ −shiftEq (± maxRefStep), plan scale 1.
        #expect(abs(corrections[3].dx - (-3.0)) <= StabilizationTuning.maxRefStep + 1e-9)
        #expect(abs(corrections[3].dy - 1.0) <= StabilizationTuning.maxRefStep + 1e-9)

        await sut.stop()
        await framesTask.value
    }

    @Test("Estimation failure freezes the previous correction (frame still delivered)")
    func estimationFailure_freezesCorrection() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 1)
        stage.state.withLock {
            $0.estimateScript = [
                .success(nil),
                .success(StabilizationVector(dx: 4.0, dy: 0)),
                .failure(StabilizationStageError.estimationFailed),
            ]
        }
        let frameLog = FrameLog()
        let framesTask = consumeFrames(sut, into: frameLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        for index in 0..<4 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.05))
        }
        #expect(await eventually { frameLog.count == 4 })

        let corrections = stage.state.withLock(\.renderCorrections)
        try #require(corrections.count == 4)
        // Frame 3 failed estimation: it re-applies frame 2's correction exactly (freeze).
        #expect(corrections[2] == corrections[1])
        #expect(corrections[1] != .zero)
        // Frame 4 (script exhausted → nil shift) also keeps the same correction.
        #expect(corrections[3] == corrections[2])

        await sut.stop()
        await framesTask.value
    }
}

// MARK: - Drops & attribution (AC-4)

@Suite("StabilizingVideoSource — drop merge & attribution (AC-4)")
struct StabilizingVideoSourceDropTests {
    @Test("Wrapped source's drops pass through with their ORIGINAL attribution")
    func wrappedDrops_passThroughUnchanged() async throws {
        let (sut, camera, _) = makeSUT(warmUpFrameCount: 10)
        let dropLog = DropLog()
        let dropsTask = consumeDrops(sut, into: dropLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        let upstream = DropEvent(
            reason: .captureDrop,
            source: .captureCameraVideo,
            count: 3,
            detectedAt: CMTime(seconds: 10, preferredTimescale: 600)
        )
        camera.emitDrop(upstream)
        #expect(await eventually { dropLog.count == 1 })
        #expect(dropLog.events.first == upstream)

        await sut.stop()
        await dropsTask.value
    }

    @Test("Slow stage + fast source: ALL induced drops carry source == .stabilizeCamera (AC-4)")
    func slowStage_dropsAttributedToStage() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 1)
        let dropLog = DropLog()
        let frameLog = FrameLog()
        let dropsTask = consumeDrops(sut, into: dropLog)
        let framesTask = consumeFrames(sut, into: frameLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())

        // Park the stage on its work queue (synchronous semaphore, the live isolation shape).
        stage.state.withLock { $0.blockRender = true }
        camera.emitFrame(makeFrame(atSeconds: 10.00))
        #expect(await eventually { stage.state.withLock(\.blockedRenderEntries) == 1 })

        // Frame 2 fills the depth-1 slot; frames 3..6 each displace their predecessor.
        for index in 1...5 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.05))
        }
        #expect(await eventually { dropLog.count == 4 })

        // The attribution contract: every induced drop names the stage — nothing leaks into
        // the wrapped source's capture counters (its streams saw no overflow).
        for event in dropLog.events {
            #expect(event.source == .stabilizeCamera)
            #expect(event.reason == .stabilizationDrops)
        }

        // Release the stage and let the survivors drain.
        stage.state.withLock { $0.blockRender = false }
        stage.gate.signal()
        #expect(await eventually { frameLog.count >= 1 })

        await sut.stop()
        await dropsTask.value
        await framesTask.value
    }

    @Test("Output overflow (no consumer) emits encoderBackpressureDrops with the stage source")
    func outputOverflow_encoderBackpressureAttribution() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 100)
        let dropLog = DropLog()
        let dropsTask = consumeDrops(sut, into: dropLog)
        // NOTE: no frames consumer — the output buffer (depth 4) must overflow.

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        for index in 0..<6 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.05))
            // Serialize deliveries so the depth-1 slot never evicts: each frame is fully
            // rendered before the next is emitted.
            let expected = index + 1
            #expect(await eventually { stage.state.withLock(\.renderCalls) == expected })
        }
        // Renders 5 and 6 overflowed the depth-4 output buffer.
        #expect(await eventually { dropLog.count == 2 })
        for event in dropLog.events {
            #expect(event.reason == .encoderBackpressureDrops)
            #expect(event.source == .stabilizeCamera)
        }

        await sut.stop()
        await dropsTask.value
    }
}

// MARK: - Bypass

@Suite("StabilizingVideoSource — bypass degradation")
struct StabilizingVideoSourceBypassTests {
    @Test("Consecutive estimation errors engage bypass: estimation stops, correction ramps, diagnostics record the time")
    func consecutiveErrors_engageBypass() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 1, consecutiveErrorLimit: 3)
        // Every estimation fails; the error path still renders with the frozen correction.
        stage.state.withLock {
            $0.estimateScript = Array(
                repeating: .failure(StabilizationStageError.estimationFailed),
                count: 10
            )
        }
        let frameLog = FrameLog()
        let framesTask = consumeFrames(sut, into: frameLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        for index in 0..<5 {
            camera.emitFrame(makeFrame(atSeconds: 10.0 + Double(index) * 0.05))
            let expected = index + 1
            #expect(await eventually { frameLog.count == expected })
        }

        // Frames 1..3 error out (limit 3 → bypass on frame 3); frames 4..5 take the bypass
        // path: estimation is deactivated once and never called again.
        #expect(stage.state.withLock(\.estimateCalls) == 3)
        #expect(await eventually { stage.state.withLock(\.deactivateCalls) == 1 })

        await sut.stop()
        await framesTask.value

        let diagnostics = await sut.stabilizationDiagnostics()
        #expect(diagnostics.bypassAtSeconds != nil)
    }

    @Test("Pool exhaustion drops the frame but does NOT feed the bypass triggers")
    func poolExhaustion_noBypass() async throws {
        // Error limit 1: ANY error-counted frame would bypass immediately — proving pool
        // exhaustion is excluded from the trigger.
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 1, consecutiveErrorLimit: 1)
        stage.state.withLock { $0.renderError = StabilizationStageError.outputPoolExhausted }
        let dropLog = DropLog()
        let dropsTask = consumeDrops(sut, into: dropLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        camera.emitFrame(makeFrame(atSeconds: 10.00))
        camera.emitFrame(makeFrame(atSeconds: 10.05))
        #expect(await eventually { dropLog.count == 2 })
        for event in dropLog.events {
            #expect(event.reason == .stabilizationDrops)
            #expect(event.source == .stabilizeCamera)
        }

        await sut.stop()
        await dropsTask.value

        let diagnostics = await sut.stabilizationDiagnostics()
        #expect(diagnostics.bypassAtSeconds == nil)
    }

    @Test("Render failure joins the shared error streak and engages bypass at the limit")
    func renderFailures_engageBypass() async throws {
        let (sut, camera, stage) = makeSUT(warmUpFrameCount: 1, consecutiveErrorLimit: 2)
        stage.state.withLock { $0.renderError = StabilizationStageError.renderFailed }
        let dropLog = DropLog()
        let dropsTask = consumeDrops(sut, into: dropLog)

        try await sut.start(anchoredTo: HostTimeAnchor.now())
        camera.emitFrame(makeFrame(atSeconds: 10.00))
        camera.emitFrame(makeFrame(atSeconds: 10.05))
        // Both frames dropped with the stage attribution; the second engages bypass.
        #expect(await eventually { dropLog.count == 2 })

        await sut.stop()
        await dropsTask.value

        let diagnostics = await sut.stabilizationDiagnostics()
        #expect(diagnostics.bypassAtSeconds != nil)
        // The diagnostics line always renders (bypass before any successful frame).
        #expect(diagnostics.latencyLine.contains("Стабилизация камеры"))
    }
}

// swiftlint:enable file_length
