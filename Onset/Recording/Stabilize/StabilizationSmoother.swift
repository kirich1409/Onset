// StabilizationSmoother.swift
// Onset
//
// #297 — pure decision core of the camera-stabilization stage.
//
// Mirrors the project's pure/impure split (`CFRNormalizer` is the model): everything in this file
// is a `nonisolated` value type with no Vision/CoreImage/CoreMedia import, deterministically
// testable on L2 with synthetic numbers. The impure GPU work (upscale, Vision registration,
// CI render) lives in `StabilizationRenderer`; the orchestration lives in `StabilizingVideoSource`.
//
// Coordinates: the smoother operates in 1080p-EQUIVALENT pixels. The stage divides the
// raw Vision shift by the estimation scale before ingest (`shiftEq = shiftRaw / estScale`) and
// multiplies the returned correction once on the way out (`correctionPlan = correctionEq ×
// planWidth / 1920`). This keeps `alpha` / `maxRefStep` at their empirically tuned meaning
// (spike #295) at any planned resolution.
//
// Sign (AC-6): `correction = ref − cum` where `cum` accumulates OBSERVED CONTENT DISPLACEMENTS
// (the `StabilizationStage.estimateShift` contract: content moved +Δ → shift = +Δ) — for a
// lock-tight reference this is `correction ≈ −displacement`, which translates the content back.
// Vision's `alignmentTransform` has the OPPOSITE native convention (it maps the floating image
// onto the reference) and is negated at the renderer boundary — never here. Empirically pinned
// end-to-end by `StabilizationSignTests`: a flipped sign lands the render ~2Δ away.

import Foundation

// MARK: - StabilizationTuning

/// Central, spec-pinned tuning constants of the stabilization stage (#297).
///
/// Every value below was chosen empirically by spike #295 or fixed by the approved spec —
/// do not retune without a new measurement round on the reference hardware.
nonisolated enum StabilizationTuning {
    /// Recenter gain of the rate-limited reference (`ref += clamp(alpha·(cum − ref), …)`).
    nonisolated static let alpha = 0.05

    /// Maximum reference movement per frame, in 1080p-equivalent pixels (0.6 px/s @60fps).
    /// The rate limit is what beats a flat EMA: a shake burst cannot drag the reference,
    /// while real slow drift (~0.06 px/s measured) passes with a 10× margin.
    nonisolated static let maxRefStep = 0.01

    /// Per-frame correction step toward zero while ramping into bypass, in PLAN pixels.
    /// Spec: "correction рампится к нулю с шагом ≤ 0.1 px/кадр" — no translation-snap.
    nonisolated static let bypassRampStepPx = 0.1

    /// Number of real frames consumed by the warm-up cadence measurement before the
    /// estimation scale is chosen. Frames 1…60 render with correction = 0 by design.
    nonisolated static let warmUpFrameCount = 60

    /// Median inter-frame interval (ms) at or above which the high estimation scale is chosen:
    /// ≥ 40 ms (≤ 25 fps — the real Brio cadence) fits the ~30 ms cost of 3× estimation.
    nonisolated static let estScaleThresholdMs = 40.0

    /// High estimation scale (3× of the 1080p working resolution) for slow cadences.
    nonisolated static let estScaleHigh = 3

    /// Low estimation scale (2×) for honest 30+ fps sources whose frame budget (≤33 ms)
    /// cannot fit the 3× estimation cost (29.6 ms p50 measured offline).
    nonisolated static let estScaleLow = 2

    /// Width of the 1080p-equivalent estimation working resolution; estimation buffers are
    /// `(1920×estScale) × (1080×estScale)` regardless of the planned camera resolution.
    nonisolated static let estimationReferenceWidth = 1920

    /// Height counterpart of `estimationReferenceWidth`.
    nonisolated static let estimationReferenceHeight = 1080

    /// Overload-window length (seconds) for the slot-eviction bypass trigger.
    nonisolated static let overloadWindowSeconds = 10.0

    /// Slot-eviction share of arrived frames above which one window counts as overloaded.
    /// Aligned with the AC-2 freshness budget (5%).
    nonisolated static let overloadDropRatio = 0.05

    /// Number of CONSECUTIVE overloaded windows required to engage bypass — protection
    /// against transients (Spotlight indexing, GPU switch).
    nonisolated static let overloadConsecutiveWindows = 2

    /// Number of CONSECUTIVE estimation/render errors (Vision + CI combined) that engages
    /// bypass. A successful frame resets the streak.
    nonisolated static let consecutiveErrorLimit = 60
}

// MARK: - StabilizationVector

/// A 2D translation in pixels — the smoother's own CoreGraphics-free vector type.
///
/// A dedicated type (not `CGVector`) keeps this pure unit free of framework imports. The
/// `Equatable` conformance is declared ON THE TYPE (not a bare extension) so the synthesized
/// witnesses are `nonisolated` under `InferIsolatedConformances` — a separate-extension
/// conformance would be inferred `@MainActor`, making `!=` unusable from nonisolated contexts
/// (issue #187 pattern; "for structs this is sufficient", no manual witness needed).
nonisolated struct StabilizationVector: Equatable {
    /// Horizontal component, px.
    nonisolated let deltaX: Double
    /// Vertical component, px.
    nonisolated let deltaY: Double

    /// The zero vector.
    nonisolated static let zero = Self(deltaX: 0, deltaY: 0)

    /// Component-wise in-place sum.
    nonisolated static func += (lhs: inout Self, rhs: Self) {
        lhs = Self(deltaX: lhs.deltaX + rhs.deltaX, deltaY: lhs.deltaY + rhs.deltaY)
    }

    /// Component-wise difference.
    nonisolated static func - (lhs: Self, rhs: Self) -> Self {
        Self(deltaX: lhs.deltaX - rhs.deltaX, deltaY: lhs.deltaY - rhs.deltaY)
    }

    /// Uniform scale.
    nonisolated static func * (lhs: Self, rhs: Double) -> Self {
        Self(deltaX: lhs.deltaX * rhs, deltaY: lhs.deltaY * rhs)
    }

    /// Component-wise clamp to `±limit` on each axis.
    nonisolated func clamped(to limit: Double) -> Self {
        Self(
            deltaX: min(max(self.deltaX, -limit), limit),
            deltaY: min(max(self.deltaY, -limit), limit)
        )
    }
}

// MARK: - StabilizationSmoother

/// Causal lock-with-slow-recenter smoother (spike #295 winner).
///
/// Per frame: `cum += shift; ref += clamp(alpha·(cum − ref), ±maxRefStep); correction = ref − cum`.
/// The reference is RATE-LIMITED, not exponentially averaged — a flat EMA lags 1.8–2.3 px on the
/// measured material; the rate limit holds the theoretical residual at 0.6 px. No deadband is
/// applied to the correction (the render runs every frame regardless); the share of zero-correction
/// frames is a separate telemetry concern.
///
/// All values are in 1080p-equivalent pixels (see the file header for the coordinate contract).
nonisolated struct StabilizationSmoother {
    /// Recenter gain. See `StabilizationTuning.alpha`.
    nonisolated let alpha: Double

    /// Reference rate limit, px/frame. See `StabilizationTuning.maxRefStep`.
    nonisolated let maxRefStep: Double

    /// Cumulative content trajectory: the running sum of ingested inter-frame shifts.
    private(set) nonisolated var cum: StabilizationVector = .zero // swiftlint:disable:this modifier_order

    /// The rate-limited lock reference the correction anchors to.
    private(set) nonisolated var ref: StabilizationVector = .zero // swiftlint:disable:this modifier_order

    /// Creates a smoother with the spec-pinned defaults.
    ///
    /// - Parameters:
    ///   - alpha: Recenter gain (default `StabilizationTuning.alpha`).
    ///   - maxRefStep: Reference rate limit in px/frame (default `StabilizationTuning.maxRefStep`).
    nonisolated init(
        alpha: Double = StabilizationTuning.alpha,
        maxRefStep: Double = StabilizationTuning.maxRefStep
    ) {
        precondition(alpha > 0 && alpha <= 1, "alpha must be in (0, 1], got \(alpha)")
        precondition(maxRefStep > 0, "maxRefStep must be positive, got \(maxRefStep)")
        self.alpha = alpha
        self.maxRefStep = maxRefStep
    }

    /// The correction for the CURRENT state without ingesting a new shift (`ref − cum`).
    ///
    /// Used by the freeze path: when Vision fails on a pair, the smoother receives no shift
    /// (`cum` unchanged) and the stage re-applies the previous correction.
    nonisolated var correction: StabilizationVector {
        self.ref - self.cum
    }

    /// Ingests one inter-frame shift (1080p-equivalent px) and returns the new correction.
    ///
    /// - Parameter shift: The Vision `alignmentTransform` translation of the frame pair,
    ///   already divided by the estimation scale.
    /// - Returns: `ref − cum` — the translation to apply to the frame (AC-6 sign: ≈ −shift
    ///   for a locked reference).
    nonisolated mutating func ingest(shift: StabilizationVector) -> StabilizationVector {
        self.cum += shift
        let pull = (self.cum - self.ref) * self.alpha
        self.ref += pull.clamped(to: self.maxRefStep)
        return self.correction
    }

    /// Moves `current` toward zero by at most `step` per axis — the bypass ramp (#297 AC-4:
    /// no translation-snap when the stage degrades).
    ///
    /// - Parameters:
    ///   - current: The correction applied to the previous frame (plan px).
    ///   - step: Maximum per-axis movement (default `StabilizationTuning.bypassRampStepPx`).
    /// - Returns: The ramped correction; reaches exactly `.zero` without overshoot.
    nonisolated static func ramp(
        _ current: StabilizationVector,
        towardZeroBy step: Double = StabilizationTuning.bypassRampStepPx
    )
    -> StabilizationVector {
        StabilizationVector(
            deltaX: self.rampComponent(current.deltaX, step: step),
            deltaY: self.rampComponent(current.deltaY, step: step)
        )
    }

    /// Moves one scalar component toward zero by at most `step`, clamping at zero.
    nonisolated private static func rampComponent(_ value: Double, step: Double) -> Double {
        if value > step { return value - step }
        if value < -step { return value + step }
        return 0
    }
}

// MARK: - StabilizationWarmUp

/// Warm-up cadence meter: measures the MEDIAN inter-frame interval over the first
/// `frameCount` real frames and picks the estimation scale (#297).
///
/// The planned fps is deliberately ignored — the Brio announces 60 fps but delivers 20–25;
/// choosing by plan would select 2× exactly where AC-1 was proven @3×. Intervals are computed
/// from `ptsHostTime` deltas of ARRIVED frames (drain side), not processing wall-clock.
nonisolated struct StabilizationWarmUp {
    /// Number of frames the warm-up consumes. See `StabilizationTuning.warmUpFrameCount`.
    nonisolated let frameCount: Int

    /// Median interval (ms) at or above which the high scale is chosen.
    nonisolated let scaleThresholdMs: Double

    /// Frames observed so far.
    private(set) nonisolated var observedFrames = 0 // swiftlint:disable:this modifier_order

    /// Inter-frame intervals collected so far, milliseconds.
    private var intervalsMs: [Double] = []

    /// PTS seconds of the previously observed frame.
    private var lastPtsSeconds: Double?

    /// Creates a warm-up meter.
    ///
    /// - Parameters:
    ///   - frameCount: Warm-up length in frames (default `StabilizationTuning.warmUpFrameCount`).
    ///   - scaleThresholdMs: Median-interval threshold for the 3× scale
    ///     (default `StabilizationTuning.estScaleThresholdMs`).
    nonisolated init(
        frameCount: Int = StabilizationTuning.warmUpFrameCount,
        scaleThresholdMs: Double = StabilizationTuning.estScaleThresholdMs
    ) {
        precondition(frameCount >= 1, "frameCount must be at least 1, got \(frameCount)")
        self.frameCount = frameCount
        self.scaleThresholdMs = scaleThresholdMs
    }

    /// `true` once the warm-up has consumed all its frames.
    nonisolated var isComplete: Bool {
        self.observedFrames >= self.frameCount
    }

    /// Median of the collected intervals, ms. `nil` while fewer than two frames arrived.
    /// Upper-median for even counts — a half-sample bias is irrelevant at the 40 ms threshold.
    nonisolated var medianIntervalMs: Double? {
        guard !self.intervalsMs.isEmpty else { return nil }
        let sorted = self.intervalsMs.sorted()
        let middleDivisor = 2
        return sorted[sorted.count / middleDivisor]
    }

    /// Records one arrived frame.
    ///
    /// - Parameter ptsSeconds: The frame's `ptsHostTime` in seconds.
    /// - Returns: The chosen estimation scale (2 or 3) exactly once — on the call that
    ///   completes the warm-up; `nil` on every other call (including after completion).
    ///   A degenerate warm-up with no measurable interval falls back to the LOW scale
    ///   (the conservative choice: 2× always fits the frame budget).
    nonisolated mutating func record(ptsSeconds: Double) -> Int? {
        guard !self.isComplete else { return nil }
        self.observedFrames += 1
        if let last = self.lastPtsSeconds {
            let millisecondsPerSecond = 1000.0
            self.intervalsMs.append((ptsSeconds - last) * millisecondsPerSecond)
        }
        self.lastPtsSeconds = ptsSeconds
        guard self.isComplete else { return nil }
        guard let median = self.medianIntervalMs else { return StabilizationTuning.estScaleLow }
        return median >= self.scaleThresholdMs
            ? StabilizationTuning.estScaleHigh
            : StabilizationTuning.estScaleLow
    }
}

// MARK: - StabilizationOverloadDetector

/// Bypass trigger (1): slot-eviction share per consecutive fixed windows (#297).
///
/// Counts frame arrivals and estimation-slot evictions in consecutive `windowSeconds` windows
/// (timed by frame PTS). A window whose eviction share exceeds `dropRatioThreshold` is
/// overloaded; `consecutiveWindowsToBypass` overloaded windows IN A ROW engage bypass.
/// ("Два ПОСЛЕДОВАТЕЛЬНЫХ окна" — consecutive tumbling windows; a clean window resets the
/// streak, which is the transient protection the spec demands.)
///
/// ONLY slot evictions feed this detector — pool-exhaustion and encoder-backpressure drops are
/// downstream-congestion symptoms that bypass cannot cure and MUST NOT be recorded here.
nonisolated struct StabilizationOverloadDetector {
    /// Window length, seconds. See `StabilizationTuning.overloadWindowSeconds`.
    nonisolated let windowSeconds: Double

    /// Eviction share above which a window is overloaded (strict `>`).
    nonisolated let dropRatioThreshold: Double

    /// Overloaded-windows-in-a-row required to engage bypass.
    nonisolated let consecutiveWindowsToBypass: Int

    /// Start of the currently open window (PTS seconds), `nil` before the first record.
    private var windowStartSeconds: Double?

    /// Frames arrived in the open window.
    private var framesInWindow = 0

    /// Slot evictions in the open window.
    private var evictionsInWindow = 0

    /// Current streak of consecutive overloaded windows.
    private(set) nonisolated var consecutiveOverloadedWindows = 0 // swiftlint:disable:this modifier_order

    /// Creates a detector with the spec-pinned defaults.
    ///
    /// - Parameters:
    ///   - windowSeconds: Window length (default `StabilizationTuning.overloadWindowSeconds`).
    ///   - dropRatioThreshold: Overload share (default `StabilizationTuning.overloadDropRatio`).
    ///   - consecutiveWindowsToBypass: Streak length engaging bypass
    ///     (default `StabilizationTuning.overloadConsecutiveWindows`).
    nonisolated init(
        windowSeconds: Double = StabilizationTuning.overloadWindowSeconds,
        dropRatioThreshold: Double = StabilizationTuning.overloadDropRatio,
        consecutiveWindowsToBypass: Int = StabilizationTuning.overloadConsecutiveWindows
    ) {
        precondition(windowSeconds > 0, "windowSeconds must be positive")
        precondition(dropRatioThreshold > 0, "dropRatioThreshold must be positive")
        precondition(consecutiveWindowsToBypass >= 1, "consecutiveWindowsToBypass must be ≥ 1")
        self.windowSeconds = windowSeconds
        self.dropRatioThreshold = dropRatioThreshold
        self.consecutiveWindowsToBypass = consecutiveWindowsToBypass
    }

    /// Records one frame arrival (and whether it evicted a pending frame from the slot).
    ///
    /// - Parameters:
    ///   - atSeconds: The frame's `ptsHostTime` in seconds (monotonically non-decreasing).
    ///   - evicted: `true` when yielding this frame displaced the previously pending frame.
    /// - Returns: `true` when bypass should engage (the streak reached the configured length).
    nonisolated mutating func record(atSeconds: Double, evicted: Bool) -> Bool {
        if self.windowStartSeconds == nil {
            self.windowStartSeconds = atSeconds
        }
        // Close every fully elapsed window before recording — a long stall spanning several
        // windows closes each one in turn (empty windows are clean and reset the streak).
        while let start = self.windowStartSeconds, atSeconds - start >= self.windowSeconds {
            self.closeWindow()
            self.windowStartSeconds = start + self.windowSeconds
        }
        self.framesInWindow += 1
        if evicted {
            self.evictionsInWindow += 1
        }
        return self.consecutiveOverloadedWindows >= self.consecutiveWindowsToBypass
    }

    /// Closes the open window: updates the overload streak and resets the window counters.
    private mutating func closeWindow() {
        let overloaded = self.framesInWindow > 0
            && Double(self.evictionsInWindow) / Double(self.framesInWindow) > self.dropRatioThreshold
        self.consecutiveOverloadedWindows = overloaded ? self.consecutiveOverloadedWindows + 1 : 0
        self.framesInWindow = 0
        self.evictionsInWindow = 0
    }
}
