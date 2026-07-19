// DropReportFormatterTests.swift
// OnsetTests
//
// Swift Testing suite (L2) for the pure DropReportFormatter — the per-session technical report text.
//
// Frame-loss is no longer shown in the UI; it is persisted to a plain-text report next to the
// recording files. These tests assert the report text contains the expected sections and values for
// both a degraded session and a clean (zero-drop) session, and that real frame loss (backpressure)
// is unambiguously separated from zero-content-loss coalescing (CFR normalization, hold repeats).
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

    /// Zero-drop breakdown used as a neutral fixture in header/structure tests.
    private func zeroBreakdown() -> DropBreakdown {
        DropBreakdown(
            captureScreen: 0,
            captureCameraVideo: 0,
            captureCameraAudio: 0,
            encodeScreen: 0,
            encodeCamera: 0,
            bpEncodeScreen: 0,
            bpEncodeCamera: 0,
            writer: 0
        )
    }

    @Test("Report contains every section header")
    func report_containsAllSections() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: self.zeroBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
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
            breakdown: DropBreakdown(
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
            dominantCause: .encode
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
            breakdown: self.zeroBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
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
            breakdown: self.zeroBreakdown(),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
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
            breakdown: DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encodeScreen: 10,
                encodeCamera: 90,
                bpEncodeScreen: 10,
                bpEncodeCamera: 90,
                writer: 0
            ),
            sessionEverDegraded: true,
            dominantCause: .encode
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
            breakdown: DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encodeScreen: 1204,
                encodeCamera: 0,
                bpEncodeScreen: 0,
                bpEncodeCamera: 0,
                writer: 0
            ),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
        )

        // CFR count appears in the coalescing section.
        #expect(text.contains("Нормализация CFR: 1204"))

        // The real-loss section must show zero encoder backpressure — CFR is not real loss.
        #expect(text.contains("Кодировщик backpressure — экран: 0"))
        #expect(text.contains("Кодировщик backpressure — камера: 0"))

        // The coalescing section must be identifiable as non-destructive.
        #expect(text.contains("Коалесция без потери содержимого"))
    }
}
