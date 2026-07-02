// DropReportFormatterTests.swift
// OnsetTests
//
// Swift Testing suite (L2) for the pure DropReportFormatter — the per-session technical report text.
//
// Frame-loss is no longer shown in the UI; it is persisted to a plain-text report next to the
// recording files. These tests assert the report text contains the expected sections and values for
// both a degraded session and a clean (zero-drop) session, and that real frame loss (backpressure)
// is unambiguously separated from zero-content-loss coalescing (CFR normalization, hold repeats).
// #297 adds the stabilization-stage lines (drops, bypass transition, latency summary).
//
import Foundation
@testable import Onset
import Testing

// MARK: - DropReportFormatter Tests

@Suite("DropReportFormatter")
struct DropReportFormatterTests {
    private func timestamp() -> Date {
        // Fixed instant so the formatted header is deterministic across runs (local time zone).
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// Breakdown factory with all-zero defaults so each test names only the counters it exercises.
    private func makeBreakdown(
        captureScreen: Int = 0,
        captureCameraVideo: Int = 0,
        captureCameraAudio: Int = 0,
        encodeScreen: Int = 0,
        encodeCamera: Int = 0,
        bpEncodeScreen: Int = 0,
        bpEncodeCamera: Int = 0,
        writer: Int = 0,
        stabilizeCamera: Int = 0,
        bpStabilizeCamera: Int = 0,
        stabilizationBypassAtSeconds: Double? = nil
    )
    -> DropBreakdown {
        DropBreakdown(
            captureScreen: captureScreen,
            captureCameraVideo: captureCameraVideo,
            captureCameraAudio: captureCameraAudio,
            encodeScreen: encodeScreen,
            encodeCamera: encodeCamera,
            bpEncodeScreen: bpEncodeScreen,
            bpEncodeCamera: bpEncodeCamera,
            writer: writer,
            stabilizeCamera: stabilizeCamera,
            bpStabilizeCamera: bpStabilizeCamera,
            stabilizationBypassAtSeconds: stabilizationBypassAtSeconds
        )
    }

    @Test("Report contains every section header")
    func report_containsAllSections() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        #expect(text.contains("Onset — техническая информация о записи"))
        #expect(text.contains("Реальные потери кадров (необратимо)"))
        #expect(text.contains("Коалесция без потери содержимого"))
        #expect(text.contains("Разбивка по источникам (все события, включая повторы без потери содержимого)"))
        #expect(text.contains("Острая деградация (всплеск backpressure):"))
        #expect(text.contains("Основная причина:"))
    }

    @Test("Degraded session: per-lane encoder counters, breakdown, degradation and cause are rendered")
    func report_degradedSession() {
        // bp total = 15 + 27 = 42; cfr = 3; hold = (18+32) − 42 − 3 = 5
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 42, captureDrops: 7, cfrNormalizationDrops: 3),
            breakdown: self.makeBreakdown(
                captureScreen: 1,
                captureCameraVideo: 2,
                captureCameraAudio: 4,
                encodeScreen: 18,
                encodeCamera: 32,
                bpEncodeScreen: 15,
                bpEncodeCamera: 27,
                writer: 12
            ),
            sessionEverDegraded: true,
            dominantCause: .encode,
            stabilizationLatencyLine: nil
        )

        // Real-loss section — per-lane encoder backpressure.
        #expect(text.contains("Кодировщик backpressure — экран: 15"))
        #expect(text.contains("Кодировщик backpressure — камера: 27"))
        // Real-loss section — capture.
        #expect(text.contains("Захват — экран: 1"))
        #expect(text.contains("Захват — камера (видео): 2"))
        #expect(text.contains("Захват — камера (аудио): 4"))
        // Zero-loss coalescing section.
        #expect(text.contains("Нормализация CFR: 3"))
        #expect(text.contains("Hold-повторы кодировщика: 5"))
        // Source breakdown section.
        #expect(text.contains("Кодировщик (экран): 18"))
        #expect(text.contains("Кодировщик (камера): 32"))
        #expect(text.contains("Запись в файл: 12"))
        // Degradation verdict + cause.
        #expect(text.contains("Острая деградация (всплеск backpressure): да"))
        #expect(text.contains("Основная причина: кодировщик"))
    }

    @Test("Clean session reads as zero drops, no degradation")
    func report_cleanSession() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        #expect(text.contains("Кодировщик backpressure — экран: 0"))
        #expect(text.contains("Кодировщик backpressure — камера: 0"))
        #expect(text.contains("Нормализация CFR: 0"))
        #expect(text.contains("Hold-повторы кодировщика: 0"))
        #expect(text.contains("Острая деградация (всплеск backpressure): нет"))
        #expect(text.contains("Основная причина: нет (деградации не было)"))
    }

    @Test("Header timestamp matches the recording file/folder naming format")
    func report_headerUsesSharedTimestampFormat() {
        let date = self.timestamp()
        let text = DropReportFormatter.report(
            timestamp: date,
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        // The header must carry the same formatted timestamp used for file/folder names.
        let expected = RecordingOutput.makeDateFormatter().string(from: date)
        #expect(text.contains("Сессия: \(expected)"))
    }

    @Test("Every DropCause maps to a non-empty Russian description")
    func causeDescription_allCases() {
        let causes: [DropCause] = [
            .notDegraded,
            .captureScreen,
            .captureCameraVideo,
            .captureCameraAudio,
            .encode,
            .writer,
            .stabilizeCamera,
        ]
        for cause in causes {
            #expect(!DropReportFormatter.causeDescription(cause).isEmpty)
        }
    }

    /// Guard: camera encoder drops appear in the camera lane, not the screen lane.
    @Test("Screen and camera encoder backpressure appear in separate report lines")
    func report_encoderDropsSplitByLane() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 100, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(
                encodeScreen: 10,
                encodeCamera: 90,
                bpEncodeScreen: 10,
                bpEncodeCamera: 90
            ),
            sessionEverDegraded: true,
            dominantCause: .encode,
            stabilizationLatencyLine: nil
        )

        #expect(text.contains("Кодировщик backpressure — экран: 10"))
        #expect(text.contains("Кодировщик backpressure — камера: 90"))
    }

    /// Guard: CFR normalization must not appear in the "real loss" section.
    /// It must appear only in the "zero-loss coalescing" section so neither count
    /// can be mistaken for lost frames.
    @Test("CFR normalization appears only in the coalescing section, not in the real-loss section")
    func report_cfrAppearsOnlyInCoalescingSection() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 1204),
            breakdown: self.makeBreakdown(encodeScreen: 1204),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        // CFR count appears in the coalescing section.
        #expect(text.contains("Нормализация CFR: 1204"))

        // The real-loss section must show zero encoder backpressure — CFR is not real loss.
        #expect(text.contains("Кодировщик backpressure — экран: 0"))
        #expect(text.contains("Кодировщик backpressure — камера: 0"))

        // The coalescing section must be identifiable as non-destructive.
        #expect(text.contains("Коалесция без потери содержимого"))
    }

    // MARK: - Stabilization lines (#297 AC-4/AC-8)

    /// AC-4: stage drops are split into stage-internal loss and output backpressure, and the
    /// per-source breakdown carries the stage's all-reason total.
    @Test("Stabilization drops render as stage-internal and output-backpressure lines")
    func report_stabilizationDropLines() {
        // stabilizeCamera total 25 = 18 stage-internal + 7 output backpressure.
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 7, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(stabilizeCamera: 25, bpStabilizeCamera: 7),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        #expect(text.contains("Стабилизация — этап (камера): 18"))
        #expect(text.contains("Стабилизация — backpressure на выходе (камера): 7"))
        #expect(text.contains("Стабилизация (камера): 25"))
    }

    /// AC-4: a bypass transition is reported with the session-relative second of the switch.
    @Test("Bypass transition renders its session-relative time")
    func report_bypassTransitionTime() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(stabilizeCamera: 40, stabilizationBypassAtSeconds: 73.4),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: "Стабилизация камеры — латентность этапа: p50=31.2 мс, p95=41.0 мс"
        )

        #expect(text.contains("Стабилизация камеры: отключена на 73-й секунде записи (перегруз)"))
    }

    /// AC-8: the latency summary line is included verbatim when the stage ran, and the bypass
    /// line explicitly states "no bypass" for a healthy stabilized session.
    @Test("Latency line is rendered verbatim with an explicit no-bypass statement")
    func report_latencyLineAndNoBypass() {
        let latencyLine = "Стабилизация камеры — латентность этапа (оценка+рендер): p50=31.2 мс, p95=41.0 мс"
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: latencyLine
        )

        #expect(text.contains(latencyLine))
        #expect(text.contains("Стабилизация камеры: переход в bypass: нет"))
    }

    /// AC-3 adjacency: with stabilization off (nil latency line) the report carries no bypass
    /// statement — the trailing stabilization block is omitted entirely.
    @Test("Stage-off session omits the stabilization block")
    func report_stageOffOmitsBypassLine() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.makeBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded,
            stabilizationLatencyLine: nil
        )

        #expect(!text.contains("переход в bypass"))
        #expect(!text.contains("латентность"))
    }
}
