// StabilizationTelemetry.swift
// Onset
//
// #297 AC-8 — in-process latency aggregation of the stabilization stage.
//
// Purity: value types only, no CoreMedia / Vision / CoreImage imports. The actor feeds
// per-frame stage latencies (estimation + render, measured around the work-queue bridge) and
// reads back the p50/p95 report line at session stop. The `os_signpost` intervals around the
// raw GPU work are emitted by `StabilizationRenderer`; this aggregator is the report-facing
// summary.

import Foundation

// MARK: - StabilizationFormat

/// Locale-independent one-decimal fixed-point formatting shared by the stage's report line and
/// its log lines.
///
/// Integer arithmetic instead of `String(format:)`: the `CVarArg` machinery behind
/// `String(format:)` is an unsafe construct under `SWIFT_STRICT_MEMORY_SAFETY = YES`, and a
/// one-decimal render simply does not need it.
nonisolated enum StabilizationFormat {
    /// Renders `value` with exactly one decimal digit (round-half-away-from-zero), e.g. `31.2`.
    nonisolated static func oneDecimal(_ value: Double) -> String {
        let tenthsPerUnit = 10
        let tenths = Int((value * Double(tenthsPerUnit)).rounded())
        let sign = tenths < 0 ? "-" : ""
        let magnitude = abs(tenths)
        return "\(sign)\(magnitude / tenthsPerUnit).\(magnitude % tenthsPerUnit)"
    }
}

// MARK: - StabilizationLatencyAggregator

/// Collects per-frame stage latencies (estimation + render, ms) and renders the AC-8 session
/// report line with p50/p95 percentiles, the chosen estimation scale, and the warm-up median
/// interval — the adaptive-threshold inputs the AC-8 measurement needs in one place.
nonisolated struct StabilizationLatencyAggregator {
    /// Recorded per-frame latencies, milliseconds. Unbounded by design: 30 min at 25 fps is
    /// ~45k doubles (≈360 KB) — negligible against the stage's buffer pools.
    private var samplesMs: [Double] = []

    /// Number of recorded samples.
    nonisolated var count: Int {
        self.samplesMs.count
    }

    /// Records one stabilized frame's total stage latency (estimation + render), ms.
    nonisolated mutating func record(totalMs: Double) {
        self.samplesMs.append(totalMs)
    }

    /// Nearest-rank percentile of the recorded samples, or `nil` when no samples exist.
    ///
    /// - Parameter fraction: The percentile as a fraction (0.5 = p50, 0.95 = p95).
    nonisolated func percentileMs(_ fraction: Double) -> Double? {
        guard !self.samplesMs.isEmpty else { return nil }
        let sorted = self.samplesMs.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * fraction))
        return sorted[index]
    }

    /// Renders the Russian report line for the session technical report (#297 AC-8).
    ///
    /// - Parameters:
    ///   - estScale: The estimation scale chosen by warm-up, or `nil` when warm-up never
    ///     completed (short session / early bypass).
    ///   - warmUpMedianIntervalMs: The warm-up's median inter-frame interval, ms — the base of
    ///     the AC-8 adaptive threshold (`p50 ≤ 0.8 × median interval`).
    ///   - errorCount: Cumulative estimation/render error count this session (never reset by a
    ///     successful frame, unlike the bypass streak) — default `0` for callers that have no
    ///     error tracking to report.
    ///   - zeroCorrectionFraction: Fraction of stabilized frames delivered with an
    ///     effectively-zero applied correction, or `nil` when no frames were stabilized.
    /// - Returns: A single report line; a stage that measured no stabilized frames states so
    ///   explicitly instead of fabricating percentiles.
    nonisolated func reportLine(
        estScale: Int?,
        warmUpMedianIntervalMs: Double?,
        errorCount: Int = 0,
        zeroCorrectionFraction: Double? = nil
    )
    -> String {
        let p50Fraction = 0.5
        let p95Fraction = 0.95
        let percentPerFraction = 100.0
        let scalePart = estScale.map { "estScale=\($0)×" } ?? "estScale=не выбран"
        let intervalPart = warmUpMedianIntervalMs
            .map { "медианный интервал warm-up=\(StabilizationFormat.oneDecimal($0)) мс" }
            ?? "медианный интервал warm-up=не измерен"
        let errorPart = "ошибок оценки/рендера: \(errorCount)"
        let zeroCorrectionPart = zeroCorrectionFraction
            .map { "доля нулевой коррекции: \(StabilizationFormat.oneDecimal($0 * percentPerFraction))%" }
            ?? "доля нулевой коррекции: не измерена"

        guard !self.samplesMs.isEmpty else {
            return "Стабилизация камеры — латентность этапа (оценка+рендер): "
                + "нет измеренных кадров (warm-up/bypass); \(scalePart); \(intervalPart); "
                + "\(errorPart); \(zeroCorrectionPart)"
        }
        // Sort once: percentileMs(_:) sorts independently per call, which would sort the
        // session's ~45k-sample array twice back-to-back at session stop for no benefit.
        let sorted = self.samplesMs.sorted()
        let p50 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * p50Fraction))]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * p95Fraction))]
        return "Стабилизация камеры — латентность этапа (оценка+рендер): "
            + "p50=\(StabilizationFormat.oneDecimal(p50)) мс, p95=\(StabilizationFormat.oneDecimal(p95)) мс "
            + "(кадров: \(self.count); \(scalePart); \(intervalPart); \(errorPart); \(zeroCorrectionPart))"
    }
}

// MARK: - StabilizationDiagnostics

/// End-of-session diagnostics of the stabilization stage, consumed by `RecordingSession` when
/// the camera pipeline stops: the latency line goes verbatim into the technical report (AC-8),
/// the bypass time is forwarded to `DropMonitor.noteStabilizationBypass` (AC-4).
///
/// `Equatable` is declared ON THE TYPE so the synthesized witnesses stay `nonisolated` under
/// `InferIsolatedConformances` (issue #187 pattern).
nonisolated struct StabilizationDiagnostics: Equatable {
    /// The AC-8 latency report line (see `StabilizationLatencyAggregator.reportLine`).
    nonisolated let latencyLine: String

    /// Session-relative seconds of the bypass transition, or `nil` when the stage never bypassed.
    nonisolated let bypassAtSeconds: Double?
}

// MARK: - StabilizationDiagnosticsProviding

/// Seam through which `RecordingSession` pulls the stage's end-of-session diagnostics without
/// knowing the concrete decorator type: the camera pipeline's source is conditionally cast to
/// this protocol at teardown (`nil`-cast for a bare `CameraSource` = stabilization OFF, which is
/// exactly the AC-3 zero-regression wiring).
nonisolated protocol StabilizationDiagnosticsProviding: Sendable {
    /// Returns the stage's diagnostics. Call after `stop()` — values are final at that point.
    func stabilizationDiagnostics() async -> StabilizationDiagnostics
}
