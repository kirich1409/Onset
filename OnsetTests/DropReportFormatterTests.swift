// DropReportFormatterTests.swift
// OnsetTests
//
// Swift Testing suite (L2) for the pure DropReportFormatter — the per-session technical report text.
//
// Frame-loss is no longer shown in the UI; it is persisted to a plain-text report next to the
// recording files. These tests assert the report text contains the expected sections and values for
// both a degraded session and a clean (zero-drop) session.
//
@testable import Onset
import Foundation
import Testing

// MARK: - DropReportFormatter Tests

@Suite("DropReportFormatter")
struct DropReportFormatterTests {
    private func timestamp() -> Date {
        // Fixed instant so the formatted header is deterministic across runs (local time zone).
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    @Test("Report contains every section header")
    func report_containsAllSections() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encode: 0,
                writer: 0
            ),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
        )

        #expect(text.contains("Onset — техническая информация о записи"))
        #expect(text.contains("Пропущенные кадры"))
        #expect(text.contains("Разбивка по источникам"))
        #expect(text.contains("Деградация в течение сессии:"))
        #expect(text.contains("Основная причина:"))
    }

    @Test("Degraded session: counters, breakdown, degradation and cause are rendered")
    func report_degradedSession() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 42, captureDrops: 7, cfrNormalizationDrops: 3),
            breakdown: DropBreakdown(
                captureScreen: 1,
                captureCameraVideo: 2,
                captureCameraAudio: 4,
                encode: 30,
                writer: 12
            ),
            sessionEverDegraded: true,
            dominantCause: .encode
        )

        // Reason counters.
        #expect(text.contains("Перегрузка кодировщика: 42"))
        #expect(text.contains("Захват: 7"))
        #expect(text.contains("Нормализация CFR: 3"))
        // Per-source breakdown.
        #expect(text.contains("Экран (захват): 1"))
        #expect(text.contains("Камера, видео (захват): 2"))
        #expect(text.contains("Камера, аудио (захват): 4"))
        #expect(text.contains("Кодировщик: 30"))
        #expect(text.contains("Запись в файл: 12"))
        // Degradation verdict + cause.
        #expect(text.contains("Деградация в течение сессии: да"))
        #expect(text.contains("Основная причина: кодировщик"))
    }

    @Test("Clean session reads as zero drops, no degradation")
    func report_cleanSession() {
        let text = DropReportFormatter.report(
            timestamp: self.timestamp(),
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encode: 0,
                writer: 0
            ),
            sessionEverDegraded: false,
            dominantCause: .notDegraded
        )

        #expect(text.contains("Перегрузка кодировщика: 0"))
        #expect(text.contains("Деградация в течение сессии: нет"))
        #expect(text.contains("Основная причина: нет (деградации не было)"))
    }

    @Test("Header timestamp matches the recording file/folder naming format")
    func report_headerUsesSharedTimestampFormat() {
        let date = self.timestamp()
        let text = DropReportFormatter.report(
            timestamp: date,
            counters: DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
            breakdown: DropBreakdown(
                captureScreen: 0,
                captureCameraVideo: 0,
                captureCameraAudio: 0,
                encode: 0,
                writer: 0
            ),
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
}
