// DropReportFormatter.swift
// Onset
//
// Per-session technical report formatter (frame-loss diagnostics persisted to disk).
//
// Replaces the live drop pill and the post-stop "пропущено N кадров" warning alert: instead of
// surfacing frame-loss in the UI, every session that produces output writes a plain-text technical
// report next to its recording files (see `RecordingSession.performStop`). This type owns ONLY the
// text formatting — it is a pure `nonisolated enum` with no I/O, no actor isolation, and no
// CoreMedia import — so the report content is deterministically unit-testable (mirrors the
// pure/impure split of `CFRNormalizer`, `CapabilityResolver`, `MenuBarLabelMapper`). File I/O
// (writing the string, POSIX permissions) lives in the impure Storage layer (`RecordingOutput`).
//
// Language: the report is a user-facing on-disk artifact, so its content is Russian (the app UI is
// Russian). Code identifiers and comments stay English per the project language policy.

import Foundation

// MARK: - DropReportFormatter

/// Pure formatter that renders a session's frame-loss diagnostics as a human-readable Russian
/// plain-text technical report.
///
/// The output is intended to be written verbatim to a `… — Техническая информация.txt` file in the
/// session output folder. It is plain text (no Markdown) so it reads cleanly in any text editor.
/// Plain integer counts are used rather than Russian pluralization — a technical file does not need
/// grammatically agreeing word forms, and plain `N` reads naturally here.
nonisolated enum DropReportFormatter {
    // MARK: - Report

    /// Builds the full technical-report text for one recording session.
    ///
    /// The report always includes every section even when no frames were lost (the all-zero case
    /// reads correctly: every counter is `0` and degradation is reported as `нет`). This is
    /// deliberate — a per-session report is written for every session that produced output, so the
    /// reader can confirm a clean recording, not only a degraded one.
    ///
    /// - Parameters:
    ///   - timestamp: Session-start timestamp, formatted with the same `YYYY-MM-DD HH.mm.ss` helper
    ///     used for the recording file/folder names so the report header matches the folder name.
    ///   - counters: Cumulative per-reason drop tallies (`DropCounters`).
    ///   - breakdown: Per-source diagnostic drop counts (`DropBreakdown`).
    ///   - sessionEverDegraded: `true` when the session transitioned to `.degraded` at least once.
    ///   - dominantCause: The backpressure stage that accumulated the most drops, or `.notDegraded`.
    /// - Returns: The complete report text, terminated by a trailing newline.
    nonisolated static func report(
        timestamp: Date,
        counters: DropCounters,
        breakdown: DropBreakdown,
        sessionEverDegraded: Bool,
        dominantCause: DropCause
    )
    -> String {
        let formattedTimestamp = RecordingOutput.makeDateFormatter().string(from: timestamp)
        let degradedLine = sessionEverDegraded ? "да" : "нет"

        return """
        Onset — техническая информация о записи
        Сессия: \(formattedTimestamp)

        Пропущенные кадры
          Перегрузка кодировщика: \(counters.encoderBackpressureDrops)
          Захват: \(counters.captureDrops)
          Нормализация CFR: \(counters.cfrNormalizationDrops)

        Разбивка по источникам
          Экран (захват): \(breakdown.captureScreen)
          Камера, видео (захват): \(breakdown.captureCameraVideo)
          Камера, аудио (захват): \(breakdown.captureCameraAudio)
          Кодировщик: \(breakdown.encode)
          Запись в файл: \(breakdown.writer)

        Деградация в течение сессии: \(degradedLine)
        Основная причина: \(self.causeDescription(dominantCause))

        """
    }

    // MARK: - Cause description

    /// Maps a `DropCause` to its Russian description for the "Основная причина" line.
    nonisolated static func causeDescription(_ cause: DropCause) -> String {
        switch cause {
        case .notDegraded:
            "нет (деградации не было)"

        case .captureScreen:
            "захват экрана"

        case .captureCameraVideo:
            "захват видео с камеры"

        case .captureCameraAudio:
            "захват аудио с камеры"

        case .encode:
            "кодировщик"

        case .writer:
            "запись в файл"
        }
    }
}
