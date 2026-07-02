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
    /// - Returns: A single report line; a stage that measured no stabilized frames states so
    ///   explicitly instead of fabricating percentiles.
    nonisolated func reportLine(estScale: Int?, warmUpMedianIntervalMs: Double?) -> String {
        let p50Fraction = 0.5
        let p95Fraction = 0.95
        let scalePart = estScale.map { "estScale=\($0)×" } ?? "estScale=не выбран"
        let intervalPart = warmUpMedianIntervalMs
            .map { "медианный интервал warm-up=\(Self.format($0)) мс" }
            ?? "медианный интервал warm-up=не измерен"
        guard let p50 = self.percentileMs(p50Fraction), let p95 = self.percentileMs(p95Fraction) else {
            return "Стабилизация камеры — латентность этапа (оценка+рендер): "
                + "нет измеренных кадров (warm-up/bypass); \(scalePart); \(intervalPart)"
        }
        return "Стабилизация камеры — латентность этапа (оценка+рендер): "
            + "p50=\(Self.format(p50)) мс, p95=\(Self.format(p95)) мс "
            + "(кадров: \(self.count); \(scalePart); \(intervalPart))"
    }

    /// Formats a millisecond value with one decimal digit, locale-independent.
    nonisolated private static func format(_ value: Double) -> String {
        String(format: "%.1f", locale: nil, value)
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
