import CoreGraphics
import CoreMedia
import CoreVideo
@testable import Onset
import os
import ScreenCaptureKit
import Testing

// no_magic_numbers is disabled file-wide: these are Swift Testing structs (no XCTest
// parent class), so the rule's `test_parent_classes` exclusion in .swiftlint.yml does
// not apply; the numeric literals here are expected-value test data, not magic numbers.
// swiftlint:disable no_magic_numbers

// MARK: - Frame status classification tests

@Suite("ScreenSource — frame status classification")
struct FrameStatusClassificationTests {
    @Test(".complete maps to .process")
    func complete_mapsToProcess() {
        #expect(classifyFrameStatus(.complete) == .process)
    }

    @Test(".idle maps to .skipStatic — NOT a drop")
    func idle_mapsToSkipStatic() {
        #expect(classifyFrameStatus(.idle) == .skipStatic)
    }

    @Test(".blank maps to .skipStatic — NOT a drop")
    func blank_mapsToSkipStatic() {
        #expect(classifyFrameStatus(.blank) == .skipStatic)
    }

    @Test(".started maps to .skipStatic")
    func started_mapsToSkipStatic() {
        #expect(classifyFrameStatus(.started) == .skipStatic)
    }

    @Test(".stopped maps to .skipStatic")
    func stopped_mapsToSkipStatic() {
        #expect(classifyFrameStatus(.stopped) == .skipStatic)
    }
}

// MARK: - T0 gating tests

@Suite("ScreenSource — T0 gating")
struct T0GatingTests {
    /// A fixed T0 anchor: 10 seconds on the host clock.
    private let anchorT0 = CMTime(value: 10, timescale: 1)

    @Test("frame strictly before T0 is dropped")
    func frameBefore_T0_isDropped() {
        let beforeT0 = CMTime(value: 9, timescale: 1)
        #expect(shouldKeepFrame(frameHostTime: beforeT0, sessionStart: self.anchorT0) == false)
    }

    @Test("frame one millisecond before T0 is dropped")
    func frameOneMillisecondBefore_T0_isDropped() {
        // 9999 ms = 9.999 s < 10.0 s
        let justBefore = CMTime(value: 9999, timescale: 1000)
        #expect(shouldKeepFrame(frameHostTime: justBefore, sessionStart: self.anchorT0) == false)
    }

    @Test("frame exactly at T0 is kept")
    func frameAt_T0_isKept() {
        #expect(shouldKeepFrame(frameHostTime: self.anchorT0, sessionStart: self.anchorT0) == true)
    }

    @Test("frame one millisecond after T0 is kept")
    func frameOneMillisecondAfter_T0_isKept() {
        // 10001 ms = 10.001 s > 10.0 s
        let justAfter = CMTime(value: 10001, timescale: 1000)
        #expect(shouldKeepFrame(frameHostTime: justAfter, sessionStart: self.anchorT0) == true)
    }

    @Test("frame strictly after T0 is kept")
    func frameAfter_T0_isKept() {
        let after = CMTime(value: 11, timescale: 1)
        #expect(shouldKeepFrame(frameHostTime: after, sessionStart: self.anchorT0) == true)
    }

    @Test("frame with T0 = zero is always kept when PTS ≥ 0")
    func zeroT0_keepsPtsAtZero() {
        let zeroT0 = CMTime.zero
        #expect(shouldKeepFrame(frameHostTime: CMTime.zero, sessionStart: zeroT0) == true)
    }

    @Test("frame with T0 = zero drops negative PTS")
    func zeroT0_dropsNegativePts() {
        let zeroT0 = CMTime.zero
        let negativePts = CMTime(value: -1, timescale: 1)
        #expect(shouldKeepFrame(frameHostTime: negativePts, sessionStart: zeroT0) == false)
    }
}

// MARK: - FrameAction equatability test

@Suite("FrameAction — equatability")
struct FrameActionEquatabilityTests {
    @Test(".process equals .process")
    func process_equalsProcess() {
        #expect(FrameAction.process == .process)
    }

    @Test(".skipStatic equals .skipStatic")
    func skipStatic_equalsSkipStatic() {
        #expect(FrameAction.skipStatic == .skipStatic)
    }

    @Test(".process does not equal .skipStatic")
    func process_doesNotEqualSkipStatic() {
        #expect(FrameAction.process != .skipStatic)
    }
}

// MARK: - L5 live-hardware micro-harness

/// Result of a `captureFrames` call — avoids a 3-member tuple (large_tuple rule).
private struct CaptureResult {
    let frames: [VideoFrame]
    let anchor: HostTimeAnchor
    /// Wall-clock seconds elapsed from `source.start` to `source.stop`.
    let elapsed: Double
}

@Suite("ScreenSource — L5 live hardware", .serialized)
struct ScreenSourceLiveTests {
    /// Requires real screen-recording permission. In CI the guard below exits early;
    /// running locally with TCC permission granted executes the full harness.
    @Test("live capture produces host-time-stamped frames")
    func liveCapture_producesFrames() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            // No TCC permission — skip gracefully so CI passes.
            return
        }

        let plan = ResolvedRecordingPlan(
            displayID: CGMainDisplayID(),
            screenWidth: 1920,
            screenHeight: 1080,
            screenFps: 30,
            cameraPlan: nil
        )
        let result = try await captureFrames(plan: plan, targetCount: 5)

        self.assertFrameCount(result.frames, expected: 5)
        self.assertHostTimePts(result.frames, anchor: result.anchor)
        self.assertMonotonic(result.frames)
        self.assertHoldRepeatFalse(result.frames)
        self.assertResolution(result.frames, plan: plan)
        self.assertPixelFormat420v(result.frames)
        self.assertCadence(elapsed: result.elapsed, count: result.frames.count, fps: plan.screenFps)

        let elapsedStr = String(format: "%.3f", result.elapsed)
        let intervalStr = String(format: "%.3f", result.elapsed / Double(result.frames.count))
        screenSourceTestLogger.info(
            "L5: \(result.frames.count)f \(plan.screenWidth)×\(plan.screenHeight) \(elapsedStr)s ~\(intervalStr)s/f"
        )
    }

    // MARK: - Capture helper

    /// Starts `ScreenSource`, collects `targetCount` frames, stops, and returns a `CaptureResult`.
    private func captureFrames(plan: ResolvedRecordingPlan, targetCount: Int) async throws -> CaptureResult {
        let config = RecordingConfiguration.mvpDefault
        let source = ScreenSource(plan: plan, config: config)
        let anchor = HostTimeAnchor.now()
        let captureStart = CMClockGetTime(CMClockGetHostTimeClock())

        try await source.start(anchoredTo: anchor)

        var collected: [VideoFrame] = []
        for await frame in source.frames {
            collected.append(frame)
            if collected.count >= targetCount { break }
        }

        let captureEnd = CMClockGetTime(CMClockGetHostTimeClock())
        await source.stop()

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(captureEnd, captureStart))
        return CaptureResult(frames: collected, anchor: anchor, elapsed: elapsed)
    }

    // MARK: - Assertion helpers

    private func assertFrameCount(_ frames: [VideoFrame], expected: Int) {
        #expect(frames.count == expected)
    }

    /// Each frame must carry a positive PTS on the host clock AND be ≥ session T0.
    private func assertHostTimePts(_ frames: [VideoFrame], anchor: HostTimeAnchor) {
        for frame in frames {
            #expect(frame.ptsHostTime.value > 0)
            #expect(frame.ptsHostTime.timescale > 0)
            #expect(
                CMTimeCompare(frame.ptsHostTime, anchor.anchorTime) >= 0,
                "PTS \(frame.ptsHostTime.value)/\(frame.ptsHostTime.timescale) predates T0"
            )
        }
    }

    private func assertMonotonic(_ frames: [VideoFrame]) {
        for index in 1..<frames.count {
            #expect(CMTimeCompare(frames[index].ptsHostTime, frames[index - 1].ptsHostTime) >= 0)
        }
    }

    private func assertHoldRepeatFalse(_ frames: [VideoFrame]) {
        for frame in frames {
            #expect(frame.isHoldRepeat == false)
        }
    }

    private func assertResolution(_ frames: [VideoFrame], plan: ResolvedRecordingPlan) {
        for frame in frames {
            let width = CVPixelBufferGetWidth(frame.pixelBuffer)
            let height = CVPixelBufferGetHeight(frame.pixelBuffer)
            #expect(width == plan.screenWidth, "width: expected \(plan.screenWidth), got \(width)")
            #expect(height == plan.screenHeight, "height: expected \(plan.screenHeight), got \(height)")
        }
    }

    /// Pixel format must be 420YpCbCr8 video-range (420v) — what SCStream delivers
    /// when configured with `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
    private func assertPixelFormat420v(_ frames: [VideoFrame]) {
        for frame in frames {
            let fmt = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            let expected = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            #expect(fmt == expected, "expected 420v (\(expected)), got \(fmt)")
        }
    }

    /// Cadence: elapsed / count must be < 1.5× the nominal frame interval.
    /// The generous bound accounts for OS scheduling jitter and the stream start ramp.
    private func assertCadence(elapsed: Double, count: Int, fps: Int) {
        let nominalInterval = 1.0 / Double(fps)
        let actualInterval = elapsed / Double(count)
        #expect(
            actualInterval < nominalInterval * 1.5,
            "cadence too slow: \(actualInterval)s/frame, limit \(nominalInterval * 1.5)s"
        )
    }
}

// MARK: - Private test logger

/// Test-scoped logger under the Onset subsystem.
nonisolated private let screenSourceTestLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "ScreenSourceTests"
)

// swiftlint:enable no_magic_numbers
