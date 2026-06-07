@testable import Onset
import Testing

// file_length is disabled: the suite grew with new duration and gap accumulator tests.
// All tests are for a single struct (StageRateAggregator) and share no external fixtures.
// swiftlint:disable file_length

// MARK: - Flush basics

@Suite("StageRateAggregator — flush basics")
struct StageRateAggregatorFlushBasicsTests {
    @Test("flush returns nil for elapsed <= 0")
    func flushNilOnZeroElapsed() {
        var agg = StageRateAggregator(lane: "test", stage: .capture, nominalFps: 30)
        let resultZero = agg.flush(elapsedSeconds: 0)
        let resultNeg = agg.flush(elapsedSeconds: -1)
        #expect(resultZero == nil)
        #expect(resultNeg == nil)
    }

    @Test("flush returns non-nil for positive elapsed even with zero activity")
    func flushNonNilOnPositiveElapsed() {
        var agg = StageRateAggregator(lane: "test", stage: .capture, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        #expect(result != nil)
    }

    @Test("flush resets counters — second flush shows zeros")
    func resetAfterFlush() throws {
        var agg = StageRateAggregator(lane: "cam", stage: .capture, nominalFps: 30)
        agg.recordFresh()
        agg.recordFresh()
        agg.recordCaptureDrop()
        let firstResult = agg.flush(elapsedSeconds: 1.0)
        let first = try #require(firstResult)
        // First line should contain non-zero fresh/didDrop rates
        #expect(first.contains("fresh=2.0"))
        #expect(first.contains("didDrop=1.0"))
        // Second flush over same window: all counters reset
        let secondResult = agg.flush(elapsedSeconds: 1.0)
        let second = try #require(secondResult)
        #expect(second.contains("fresh=0.0"))
        #expect(second.contains("didDrop=0.0"))
    }
}

// MARK: - Rate math

@Suite("StageRateAggregator — rate math")
struct StageRateAggregatorRateMathTests {
    @Test("fresh rate = count / elapsed")
    func freshRateComputation() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .capture, nominalFps: 30)
        for _ in 0..<30 {
            agg.recordFresh()
        }
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("fresh=30.0"))
    }

    @Test("rate rounds correctly for fractional fps")
    func fractionalRate() throws {
        var agg = StageRateAggregator(lane: "cam", stage: .capture, nominalFps: 30)
        for _ in 0..<15 {
            agg.recordFresh()
        }
        // 15 frames / 2.0 s = 7.5
        let result = agg.flush(elapsedSeconds: 2.0)
        let line = try #require(result)
        #expect(line.contains("fresh=7.5"))
    }

    @Test("overflow rate computation")
    func overflowRate() throws {
        var agg = StageRateAggregator(lane: "cam", stage: .capture, nominalFps: 30)
        agg.recordOverflow()
        agg.recordOverflow()
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("overflow=2.0"))
    }
}

// MARK: - Capture stage key set and ordering

@Suite("StageRateAggregator — capture stage format")
struct StageRateAggregatorCaptureFormatTests {
    @Test("camera capture line has correct key order and values")
    func cameraCaptureLineFormat() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .capture, nominalFps: 30)
        agg.recordFresh()
        agg.recordCaptureDrop()
        agg.recordOverflow()
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        // Key order: lane stage fresh didDrop overflow gap_ms_avg gap_ms_max nominal win_s
        let expected = "lane=camera stage=capture fresh=1.0 didDrop=1.0 overflow=1.0"
            + " gap_ms_avg=0.0 gap_ms_max=0.0 nominal=30 win_s=1.0"
        #expect(line == expected)
    }

    @Test("screen capture line includes idle key after overflow")
    func screenCaptureLineHasIdleKey() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .capture, nominalFps: 60)
        agg.recordFresh()
        agg.recordIdle()
        agg.recordIdle()
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        let expected = "lane=screen stage=capture fresh=1.0 didDrop=0.0 overflow=0.0"
            + " gap_ms_avg=0.0 gap_ms_max=0.0 idle=2.0 nominal=60 win_s=1.0"
        #expect(line == expected)
    }

    @Test("camera capture line omits idle key")
    func cameraCaptureLineOmitsIdle() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .capture, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(!line.contains("idle="))
    }
}

// MARK: - Encoder stage key set and ordering

@Suite("StageRateAggregator — encoder stage format")
struct StageRateAggregatorEncoderFormatTests {
    @Test("encoder line has all expected keys in order")
    func encoderLineKeyOrder() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        agg.recordFresh()
        agg.recordEncodedReal()
        agg.recordDropDup()
        agg.recordHold()
        agg.recordGateDrop()
        agg.recordVTError()
        agg.recordEmit()
        agg.recordTickLag(lagMs: 2.0)
        agg.recordCatchupBatch(size: 3)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        // Verify key presence and ordering by checking prefix and substrings
        #expect(line.hasPrefix("lane=screen stage=encoder"))
        #expect(line.contains(" fresh=1.0 "))
        #expect(line.contains(" didDrop=0 "))
        #expect(line.contains(" overflow=0 "))
        #expect(line.contains(" enc_real=1.0 "))
        #expect(line.contains(" drop_dup=1.0 "))
        #expect(line.contains(" holds=1.0 "))
        #expect(line.contains(" gate_drop=1.0 "))
        #expect(line.contains(" vt_err=1.0 "))
        #expect(line.contains(" emit_rate=1.0 "))
        #expect(line.contains(" nominal=30 "))
        #expect(line.contains(" tick_lag_ms_avg=2.0 "))
        #expect(line.contains(" tick_lag_ms_max=2.0 "))
        #expect(line.contains(" catchup_max=3 "))
        #expect(line.contains(" cap_overflow=0 "))
        #expect(line.contains(" enc_ms_avg="))
        #expect(line.contains(" enc_ms_max="))
        #expect(line.contains(" pend_ms_avg="))
        #expect(line.contains(" pend_ms_max="))
        #expect(line.contains(" pending_max="))
        #expect(line.contains(" ing_ms_avg="))
        #expect(line.contains(" ing_ms_max="))
        #expect(line.hasSuffix("win_s=1.0"))
    }

    @Test("encoder line emits didDrop=0 and overflow=0 as fixed constants")
    func encoderFixedZeroKeys() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" didDrop=0 "))
        #expect(line.contains(" overflow=0 "))
    }

    @Test("zero-activity encoder line emits all keys as zero rates")
    func encoderZeroActivityLine() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("fresh=0.0"))
        #expect(line.contains("enc_real=0.0"))
        #expect(line.contains("tick_lag_ms_avg=0.0"))
        #expect(line.contains("tick_lag_ms_max=0.0"))
        #expect(line.contains("catchup_max=0"))
    }
}

// MARK: - Clock health accumulators

@Suite("StageRateAggregator — clock health")
struct StageRateAggregatorClockHealthTests {
    @Test("tick-lag avg is sum / count")
    func tickLagAverage() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        agg.recordTickLag(lagMs: 1.0)
        agg.recordTickLag(lagMs: 3.0)
        // avg = (1.0 + 3.0) / 2 = 2.0
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("tick_lag_ms_avg=2.0"))
    }

    @Test("tick-lag max tracks the highest observed lag")
    func tickLagMax() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        agg.recordTickLag(lagMs: 1.0)
        agg.recordTickLag(lagMs: 5.0)
        agg.recordTickLag(lagMs: 2.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("tick_lag_ms_max=5.0"))
    }

    @Test("catchup_max tracks the largest batch seen in the window")
    func catchupMax() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        agg.recordCatchupBatch(size: 2)
        agg.recordCatchupBatch(size: 7)
        agg.recordCatchupBatch(size: 3)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("catchup_max=7"))
    }

    @Test("clock-health accumulators reset after flush")
    func clockHealthResetsAfterFlush() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)
        agg.recordTickLag(lagMs: 10.0)
        agg.recordCatchupBatch(size: 5)
        _ = agg.flush(elapsedSeconds: 1.0)
        let secondResult = agg.flush(elapsedSeconds: 1.0)
        let second = try #require(secondResult)
        #expect(second.contains("tick_lag_ms_avg=0.0"))
        #expect(second.contains("tick_lag_ms_max=0.0"))
        #expect(second.contains("catchup_max=0"))
    }

    @Test("tick-lag resets across flush windows — second window reflects only second-window lags")
    func flush_tickLag_resetAcrossWindows() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .encoder, nominalFps: 30)

        // First window: two samples at 10 ms and 20 ms.
        agg.recordTickLag(lagMs: 10.0)
        agg.recordTickLag(lagMs: 20.0)
        _ = agg.flush(elapsedSeconds: 1.0)

        // Second window: two different samples at 3 ms and 5 ms.
        agg.recordTickLag(lagMs: 3.0)
        agg.recordTickLag(lagMs: 5.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)

        // avg = (3.0 + 5.0) / 2 = 4.0; max = 5.0 — must reflect only the second window.
        #expect(line.contains("tick_lag_ms_avg=4.0"), "avg must be second-window avg, got: \(line)")
        #expect(line.contains("tick_lag_ms_max=5.0"), "max must be second-window max, got: \(line)")
    }
}

// MARK: - Writer stage episode tracking

@Suite("StageRateAggregator — writer episode tracking")
struct StageRateAggregatorEpisodeTests {
    @Test("writer line includes not_ready_episodes and not_ready_total_ms")
    func writerLineIncludesEpisodeKeys() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("not_ready_episodes=0"))
        #expect(line.contains("not_ready_total_ms=0.0"))
    }

    @Test("completed episode accumulates duration in total_ms")
    func completedEpisodeDuration() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        agg.openEpisode(nowSeconds: 1.0)
        agg.closeEpisode(nowSeconds: 1.2)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        // 0.2 s = 200 ms
        #expect(line.contains("not_ready_episodes=1"))
        #expect(line.contains("not_ready_total_ms=200.0"))
    }

    @Test("open episode does not count until closed")
    func openEpisodeNotCounted() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        agg.openEpisode(nowSeconds: 0.5)
        // Episode still open at flush time
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        // Episode count = 0 (not closed), total_ms = 0
        #expect(line.contains("not_ready_episodes=0"))
        #expect(line.contains("not_ready_total_ms=0.0"))
    }

    @Test("open episode preserves start time across flush boundary")
    func episodeSpanningFlushBoundary() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        // Open at t=0.5; flush at t≈1.0; close at t=1.3 (in the next window)
        agg.openEpisode(nowSeconds: 0.5)
        _ = agg.flush(elapsedSeconds: 1.0)
        // After flush: episode still active, start time preserved
        agg.closeEpisode(nowSeconds: 1.3)
        let secondResult = agg.flush(elapsedSeconds: 1.0)
        let second = try #require(secondResult)
        // Duration from original start: 1.3 - 0.5 = 0.8 s = 800 ms
        #expect(second.contains("not_ready_episodes=1"))
        #expect(second.contains("not_ready_total_ms=800.0"))
    }

    @Test("multiple episodes in one window accumulate correctly")
    func multipleEpisodesInWindow() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .writer, nominalFps: 30)
        agg.openEpisode(nowSeconds: 0.0)
        agg.closeEpisode(nowSeconds: 0.1) // 100 ms
        agg.openEpisode(nowSeconds: 0.5)
        agg.closeEpisode(nowSeconds: 0.7) // 200 ms
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("not_ready_episodes=2"))
        #expect(line.contains("not_ready_total_ms=300.0"))
    }

    @Test("writer line key order: fresh not_ready_episodes not_ready_total_ms win_s")
    func writerLineKeyOrder() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        agg.recordFresh()
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        let expected = "lane=screen stage=writer fresh=1.0"
            + " not_ready_episodes=0 not_ready_total_ms=0.0"
            + " win_s=1.0"
        #expect(line == expected)
    }

    @Test("openEpisode is idempotent — second open while active is ignored")
    func openEpisodeIdempotent() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        agg.openEpisode(nowSeconds: 1.0)
        agg.openEpisode(nowSeconds: 5.0) // should NOT reset the start to 5.0
        agg.closeEpisode(nowSeconds: 2.0)
        let result = agg.flush(elapsedSeconds: 5.0)
        let line = try #require(result)
        // Duration: 2.0 - 1.0 = 1.0 s = 1000 ms (not 2.0 - 5.0 = -3.0 ms clamped to 0)
        #expect(line.contains("not_ready_total_ms=1000.0"))
    }

    @Test("closeEpisode is a no-op when no episode is active")
    func closeEpisodeNoOp() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .writer, nominalFps: 30)
        agg.closeEpisode(nowSeconds: 1.0) // no active episode
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains("not_ready_episodes=0"))
    }
}

// MARK: - win_s formatting

@Suite("StageRateAggregator — win_s field")
struct StageRateAggregatorWinSTests {
    @Test("win_s reflects the passed elapsedSeconds")
    func winSReflectsElapsed() throws {
        var agg = StageRateAggregator(lane: "cam", stage: .capture, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.05)
        let line = try #require(result)
        #expect(line.contains("win_s=1.1"))
    }
}

// MARK: - Encoder duration accumulators

@Suite("StageRateAggregator — encoder duration keys")
struct StageRateAggregatorEncoderDurationTests {
    @Test("enc_ms_avg is sum / count; enc_ms_max is the largest observed")
    func encCallDuration() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        agg.recordEncodeCall(durationMs: 2.0)
        agg.recordEncodeCall(durationMs: 8.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" enc_ms_avg=5.0 "))
        #expect(line.contains(" enc_ms_max=8.0 "))
    }

    @Test("pend_ms_avg and pend_ms_max accumulate pendingFrameCount query durations")
    func pendQueryDuration() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        agg.recordPendingQuery(durationMs: 1.0)
        agg.recordPendingQuery(durationMs: 3.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" pend_ms_avg=2.0 "))
        #expect(line.contains(" pend_ms_max=3.0 "))
    }

    @Test("pending_max tracks the highest pending frame count")
    func pendingMax() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        agg.recordPendingValue(4)
        agg.recordPendingValue(9)
        agg.recordPendingValue(2)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" pending_max=9 "))
    }

    @Test("ing_ms_avg and ing_ms_max accumulate ingest durations")
    func ingestDuration() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        agg.recordIngest(durationMs: 4.0)
        agg.recordIngest(durationMs: 6.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" ing_ms_avg=5.0 "))
        #expect(line.contains(" ing_ms_max=6.0 "))
    }

    @Test("encoder duration accumulators reset after flush")
    func encoderDurationsResetAfterFlush() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        agg.recordEncodeCall(durationMs: 10.0)
        agg.recordPendingQuery(durationMs: 5.0)
        agg.recordPendingValue(7)
        agg.recordIngest(durationMs: 3.0)
        _ = agg.flush(elapsedSeconds: 1.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" enc_ms_avg=0.0 "))
        #expect(line.contains(" enc_ms_max=0.0 "))
        #expect(line.contains(" pend_ms_avg=0.0 "))
        #expect(line.contains(" pend_ms_max=0.0 "))
        #expect(line.contains(" pending_max=0 "))
        #expect(line.contains(" ing_ms_avg=0.0 "))
        #expect(line.contains(" ing_ms_max=0.0 "))
    }

    @Test("zero-activity encoder line has all duration keys at zero")
    func encoderDurationZeroActivity() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .encoder, nominalFps: 30)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" enc_ms_avg=0.0 "))
        #expect(line.contains(" enc_ms_max=0.0 "))
        #expect(line.contains(" pend_ms_avg=0.0 "))
        #expect(line.contains(" pend_ms_max=0.0 "))
        #expect(line.contains(" pending_max=0 "))
        #expect(line.contains(" ing_ms_avg=0.0 "))
        #expect(line.contains(" ing_ms_max=0.0 "))
    }
}

// MARK: - Delivery gap accumulators

@Suite("StageRateAggregator — delivery gap keys")
struct StageRateAggregatorDeliveryGapTests {
    @Test("gap_ms_avg is sum / count; gap_ms_max is the largest observed")
    func gapAvgMax() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .capture, nominalFps: 30)
        agg.recordDeliveryGap(durationMs: 30.0)
        agg.recordDeliveryGap(durationMs: 50.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" gap_ms_avg=40.0 "))
        #expect(line.contains(" gap_ms_max=50.0 "))
    }

    @Test("gap keys emit zero when no gaps were recorded (screen source)")
    func gapZeroForScreenSource() throws {
        var agg = StageRateAggregator(lane: "screen", stage: .capture, nominalFps: 60)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" gap_ms_avg=0.0 "))
        #expect(line.contains(" gap_ms_max=0.0 "))
    }

    @Test("gap accumulators reset after flush")
    func gapResetsAfterFlush() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .capture, nominalFps: 30)
        agg.recordDeliveryGap(durationMs: 40.0)
        _ = agg.flush(elapsedSeconds: 1.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        #expect(line.contains(" gap_ms_avg=0.0 "))
        #expect(line.contains(" gap_ms_max=0.0 "))
    }

    @Test("gap_ms_avg and gap_ms_max appear between overflow and nominal in camera line")
    func gapKeyOrderInCameraLine() throws {
        var agg = StageRateAggregator(lane: "camera", stage: .capture, nominalFps: 30)
        agg.recordDeliveryGap(durationMs: 33.0)
        let result = agg.flush(elapsedSeconds: 1.0)
        let line = try #require(result)
        // Verify ordering via expected exact key sequence: overflow … gap_ms_avg … gap_ms_max … nominal
        // Split into tokens and check positional order without importing Foundation.
        let tokens = line.split(separator: " ").map(String.init)
        let overflowIdx = tokens.firstIndex { $0.hasPrefix("overflow=") }
        let gapAvgIdx = tokens.firstIndex { $0.hasPrefix("gap_ms_avg=") }
        let gapMaxIdx = tokens.firstIndex { $0.hasPrefix("gap_ms_max=") }
        let nominalIdx = tokens.firstIndex { $0.hasPrefix("nominal=") }
        guard let overflowPos = overflowIdx,
              let gapAvgPos = gapAvgIdx,
              let gapMaxPos = gapMaxIdx,
              let nominalPos = nominalIdx
        else {
            Issue.record("Missing expected key in: \(line)")
            return
        }
        #expect(overflowPos < gapAvgPos, "overflow must precede gap_ms_avg")
        #expect(gapAvgPos < gapMaxPos, "gap_ms_avg must precede gap_ms_max")
        #expect(gapMaxPos < nominalPos, "gap_ms_max must precede nominal")
    }
}

// MARK: - Duration.totalSeconds ms conversion

@Suite("Duration.totalSeconds — ms conversion")
struct DurationTotalSecondsMsTests {
    // Tolerance of 1 µs (0.001 ms) — floating-point conversion of attoseconds.
    private static let toleranceMs = 0.001

    @Test("5 ms duration converts to ≈ 5.0 ms via totalSeconds * 1000")
    func fiveMilliseconds() {
        let dur = Duration.milliseconds(5)
        let elapsedMs = dur.totalSeconds * 1000
        #expect(abs(elapsedMs - 5.0) < DurationTotalSecondsMsTests.toleranceMs)
    }

    @Test("1 s duration converts to ≈ 1000.0 ms via totalSeconds * 1000")
    func oneSecond() {
        let dur = Duration.seconds(1)
        let elapsedMs = dur.totalSeconds * 1000
        #expect(abs(elapsedMs - 1000.0) < DurationTotalSecondsMsTests.toleranceMs)
    }

    @Test("1500 ms duration converts to ≈ 1500.0 ms via totalSeconds * 1000")
    func oneSecondAndHalf() {
        let dur = Duration.milliseconds(1500)
        let elapsedMs = dur.totalSeconds * 1000
        #expect(abs(elapsedMs - 1500.0) < DurationTotalSecondsMsTests.toleranceMs)
    }
}
