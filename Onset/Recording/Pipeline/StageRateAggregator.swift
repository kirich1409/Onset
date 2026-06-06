import os

// MARK: - TelemetryStage

/// The stage within a recording pipeline that owns a `StageRateAggregator`.
///
/// `rawValue` is the wire-format token emitted in the `stage=` field of every telemetry line.
/// Keep these stable — log parsers depend on the exact strings.
nonisolated enum TelemetryStage: String {
    case capture
    case encoder
    case writer
}

// MARK: - StageRateAggregator

/// Pure value-type accumulator for per-stage cadence telemetry.
///
/// ### Design
/// No clock reads, no logging, no side effects. Each producer holds one instance.
/// `mutating func flush(elapsedSeconds:)` returns a formatted `key=value` line and
/// resets all accumulators so the next window starts clean.
///
/// ### Key set
/// The key set is fixed per-stage at init (determined by `stage`). All produced keys
/// are always emitted, including zeros — a zero line is itself a signal.
///
/// ### Thread safety
/// The struct itself is not thread-safe. When mutation happens on one queue and
/// flush is called from another isolation domain, wrap the instance in
/// `OSAllocatedUnfairLock<StageRateAggregator>`.
nonisolated struct StageRateAggregator {
    // MARK: - Identity

    let lane: String // "screen" / "camera"
    let stage: TelemetryStage
    let nominalFps: Int

    // MARK: - Cadence counters

    private var fresh = 0 // real frames / successful appends
    private var didDrop = 0 // AVCapture-level drops (capture stage only)
    private var overflow = 0 // AsyncStream overflow drops (capture stage only)
    private var encodedReal = 0 // distinct real-frame encodes (encoder stage only)
    private var dropDup = 0 // CFR duplicate / pre-anchor drops (encoder only)
    private var holds = 0 // hold frames submitted (encoder only)
    private var gateDrop = 0 // backpressure gate drops (encoder only)
    private var vtErr = 0 // VTCompressionSession encode errors (encoder only)
    private var emitCount = 0 // slots actually emitted to encodedSamples (encoder only)
    private var idle = 0 // SCK idle / skipStatic callbacks (capture/screen only)

    // MARK: - Not-ready episode tracking (writer only)

    private var notReadyEpisodes = 0
    private var notReadyTotalMs = 0.0
    /// `nil` when no episode is active; non-nil holds the episode start in wall-clock seconds.
    private var episodeStart: Double?

    // MARK: - Clock-health accumulators (encoder only)

    // Tick lag: actual-vs-deadline gap at each clockTick call.
    private var tickLagSumMs = 0.0
    private var tickLagMaxMs = 0.0
    private var tickLagSamples = 0

    /// Maximum catch-up batch size observed in this window.
    private var catchupMax = 0

    /// Count of catch-up batches that were capped short (real frame deferred) in this window.
    private var capOverflow = 0

    // MARK: - Init

    /// Creates an aggregator for one stage of one lane.
    ///
    /// - Parameters:
    ///   - lane: "screen" or "camera" (passed from the owning component).
    ///   - stage: Which pipeline stage this aggregator represents.
    ///   - nominalFps: The target frame rate for the lane; used as a sanity signal in the line.
    nonisolated init(lane: String, stage: TelemetryStage, nominalFps: Int) {
        self.lane = lane
        self.stage = stage
        self.nominalFps = nominalFps
    }

    // MARK: - Increment API (capture stage)

    /// Counts a fresh frame yielded downstream (capture stage).
    mutating func recordFresh() {
        self.fresh += 1
    }

    /// Counts an AVCapture-level drop (capture stage — `didDrop` delegate callback).
    mutating func recordCaptureDrop() {
        self.didDrop += 1
    }

    /// Counts an AsyncStream overflow drop (capture stage — `.dropped` yield result).
    mutating func recordOverflow() {
        self.overflow += 1
    }

    /// Counts a skipStatic / idle SCK callback (screen capture only).
    mutating func recordIdle() {
        self.idle += 1
    }

    // MARK: - Increment API (encoder stage)

    /// Counts a real encoded frame (distinct new slot, not a hold).
    mutating func recordEncodedReal() {
        self.encodedReal += 1
    }

    /// Counts a CFR duplicate or pre-anchor drop.
    mutating func recordDropDup() {
        self.dropDup += 1
    }

    /// Counts a hold frame submitted.
    mutating func recordHold() {
        self.holds += 1
    }

    /// Counts a backpressure gate drop (pendingFrameCount exceeded maxPendingFrames).
    mutating func recordGateDrop() {
        self.gateDrop += 1
    }

    /// Counts a VTCompressionSession encode error (non-noErr status).
    mutating func recordVTError() {
        self.vtErr += 1
    }

    /// Counts a slot emitted on `encodedSamples` (counted at successful `encodeFrame` submission,
    /// actor-isolated; not from the VT output callback).
    mutating func recordEmit() {
        self.emitCount += 1
    }

    // MARK: - Increment API (clock health, encoder stage)

    /// Records the measured lag between the current time and the expected deadline at a
    /// `clockTick(nowSeconds:)` call.
    ///
    /// - Parameter lagMs: `|now − deadline| * 1000`. Always non-negative.
    mutating func recordTickLag(lagMs: Double) {
        self.tickLagSumMs += lagMs
        if lagMs > self.tickLagMaxMs {
            self.tickLagMaxMs = lagMs
        }
        self.tickLagSamples += 1
    }

    /// Records the number of hold slots emitted in one catch-up batch (from
    /// `catchUpHolds` or `catchUpThenEncode`); updates the per-window maximum.
    mutating func recordCatchupBatch(size: Int) {
        if size > self.catchupMax {
            self.catchupMax = size
        }
    }

    /// Counts a catch-up batch that was capped short — the real frame's slot was not included
    /// because the hold count reached `holdCapSlots` (encoder only).
    mutating func recordCapOverflow() {
        self.capOverflow += 1
    }

    // MARK: - Episode tracking API (writer stage)

    /// Opens a not-ready episode at `nowSeconds` if one is not already open.
    mutating func openEpisode(nowSeconds: Double) {
        guard self.episodeStart == nil else { return }
        self.episodeStart = nowSeconds
    }

    /// Closes the active not-ready episode at `nowSeconds`, accumulating its duration.
    mutating func closeEpisode(nowSeconds: Double) {
        guard let start = self.episodeStart else { return }
        self.episodeStart = nil
        // swiftlint:disable:next no_magic_numbers
        let durationMs = (nowSeconds - start) * 1000
        self.notReadyTotalMs += max(0, durationMs)
        self.notReadyEpisodes += 1
    }

    // MARK: - Test accessors

    /// The raw hold-frame count accumulated since the last flush.
    /// Exposed for L2 tests that verify clock-driven holds are counted.
    var holdsCount: Int {
        self.holds
    }

    /// The raw cap-overflow count accumulated since the last flush.
    /// Exposed for L2 tests that verify cappedShort batches are counted.
    var capOverflowCount: Int {
        self.capOverflow
    }

    // MARK: - Flush

    /// Returns a formatted telemetry line and resets all accumulators.
    ///
    /// - Parameter elapsedSeconds: The actual wall-clock seconds that elapsed since the
    ///   previous flush. Rates are computed as `count / elapsedSeconds`. Passing a
    ///   value <= 0 is invalid and returns `nil` (prevents division by zero).
    /// - Returns: A machine-parseable `key=value` string, or `nil` when `elapsedSeconds <= 0`.
    ///
    /// ### Format contract
    /// Stable key order. All keys produced by the stage are always present (including 0).
    /// Keys not relevant to the stage are omitted (e.g. `enc_real` is absent for capture).
    mutating func flush(elapsedSeconds: Double) -> String? {
        guard elapsedSeconds > 0 else { return nil }
        let line: String = switch self.stage {
        case .capture:
            self.captureFlushLine(elapsedSeconds: elapsedSeconds)

        case .encoder:
            self.encoderFlushLine(elapsedSeconds: elapsedSeconds)

        case .writer:
            self.writerFlushLine(elapsedSeconds: elapsedSeconds)
        }
        self.reset()
        return line
    }

    private func captureFlushLine(elapsedSeconds: Double) -> String {
        let freshRate = self.rate(self.fresh, over: elapsedSeconds)
        let dropRate = self.rate(self.didDrop, over: elapsedSeconds)
        let overflowRate = self.rate(self.overflow, over: elapsedSeconds)
        let base = "lane=\(self.lane) stage=\(self.stage.rawValue)"
            + " fresh=\(self.fmt(freshRate))"
            + " didDrop=\(self.fmt(dropRate))"
            + " overflow=\(self.fmt(overflowRate))"
        if self.lane == "screen" {
            return base
                + " idle=\(self.fmt(self.rate(self.idle, over: elapsedSeconds)))"
                + " nominal=\(self.nominalFps)"
                + " win_s=\(self.fmt(elapsedSeconds))"
        }
        return base + " nominal=\(self.nominalFps)" + " win_s=\(self.fmt(elapsedSeconds))"
    }

    private func encoderFlushLine(elapsedSeconds: Double) -> String {
        let lagAvg = self.tickLagSamples > 0 ? self.tickLagSumMs / Double(self.tickLagSamples) : 0.0
        return "lane=\(self.lane) stage=\(self.stage.rawValue)"
            + " fresh=\(self.fmt(self.rate(self.fresh, over: elapsedSeconds)))"
            + " didDrop=0"
            + " overflow=0"
            + " enc_real=\(self.fmt(self.rate(self.encodedReal, over: elapsedSeconds)))"
            + " drop_dup=\(self.fmt(self.rate(self.dropDup, over: elapsedSeconds)))"
            + " holds=\(self.fmt(self.rate(self.holds, over: elapsedSeconds)))"
            + " gate_drop=\(self.fmt(self.rate(self.gateDrop, over: elapsedSeconds)))"
            + " vt_err=\(self.fmt(self.rate(self.vtErr, over: elapsedSeconds)))"
            + " emit_rate=\(self.fmt(self.rate(self.emitCount, over: elapsedSeconds)))"
            + " nominal=\(self.nominalFps)"
            + " tick_lag_ms_avg=\(self.fmt(lagAvg))"
            + " tick_lag_ms_max=\(self.fmt(self.tickLagMaxMs))"
            + " catchup_max=\(self.catchupMax)"
            + " cap_overflow=\(self.capOverflow)"
            + " win_s=\(self.fmt(elapsedSeconds))"
    }

    private func writerFlushLine(elapsedSeconds: Double) -> String {
        "lane=\(self.lane) stage=\(self.stage.rawValue)"
            + " fresh=\(self.fmt(self.rate(self.fresh, over: elapsedSeconds)))"
            + " not_ready_episodes=\(self.notReadyEpisodes)"
            + " not_ready_total_ms=\(self.fmt(self.notReadyTotalMs))"
            + " win_s=\(self.fmt(elapsedSeconds))"
    }

    // MARK: - Private helpers

    private func rate(_ count: Int, over elapsed: Double) -> Double {
        Double(count) / elapsed
    }

    /// Formats `value` to one decimal place without `String(format:)`, which trips
    /// `SWIFT_STRICT_MEMORY_SAFETY` (the project enables strict memory safety).
    private func fmt(_ value: Double) -> String {
        // Round to 1 decimal place using integer arithmetic to avoid CVarArg.
        // swiftlint:disable no_magic_numbers
        let scaled = Int((value * 10).rounded())
        let whole = scaled / 10
        let frac = abs(scaled % 10)
        // swiftlint:enable no_magic_numbers
        return "\(whole).\(frac)"
    }

    private mutating func reset() {
        self.fresh = 0
        self.didDrop = 0
        self.overflow = 0
        self.encodedReal = 0
        self.dropDup = 0
        self.holds = 0
        self.gateDrop = 0
        self.vtErr = 0
        self.emitCount = 0
        self.idle = 0
        // Episode tracking: carry forward any OPEN episode (do not lose start time).
        // Closed-episode counters reset; open-episode start time is preserved.
        self.notReadyEpisodes = 0
        self.notReadyTotalMs = 0
        // episodeStart intentionally not reset — open episode spans flush windows.
        self.tickLagSumMs = 0
        self.tickLagMaxMs = 0
        self.tickLagSamples = 0
        self.catchupMax = 0
        self.capOverflow = 0
    }
}

// MARK: - Telemetry logger

/// Shared logger for all per-stage cadence telemetry lines.
///
/// Category "telemetry" at `.notice` level: persisted by default in unified logging,
/// visible in `log show` without --info/--debug flags. A single line per ~1 second
/// per emitter.
///
/// Privacy: each producer builds the complete line as a plain `String` and logs it with
/// a single `.public` interpolation so privacy annotations cannot be forgotten per-field.
nonisolated let telemetryLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "telemetry"
)
