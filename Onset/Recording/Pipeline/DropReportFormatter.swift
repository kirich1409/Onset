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
    ///   - snapshot: The session's drop health (cumulative counters, degradation latch,
    ///     dominant cause) exactly as `DropMonitor.snapshot()` produced it.
    ///   - breakdown: Per-source diagnostic drop counts (`DropBreakdown`).
    ///   - stabilizationLatencyLine: The stage's latency summary (#297 AC-8), or `nil` when the
    ///     stabilization stage was not active this session (the block is then omitted entirely).
    /// - Returns: The complete report text, terminated by a trailing newline.
    nonisolated static func report(
        timestamp: Date,
        snapshot: DropHealthSnapshot,
        breakdown: DropBreakdown,
        stabilizationLatencyLine: String?
    )
    -> String {
        let counters = snapshot.counters
        let formattedTimestamp = RecordingOutput.makeDateFormatter().string(from: timestamp)
        let degradedLine = snapshot.sessionEverDegraded ? "да" : "нет"
        let holdDrops = self.holdDrops(breakdown: breakdown, counters: counters)

        let stabilizationBlock = self.stabilizationBlock(
            bypassAtSeconds: breakdown.stabilizationBypassAtSeconds,
            latencyLine: stabilizationLatencyLine
        )

        // AC-3: gated by the SAME signal as the trailing block — `stabilizationLatencyLine != nil`
        // — so an OFF report carries no stabilization mention at all, byte-identical to the
        // pre-#297 format.
        let stabilizationFragments = self.stabilizationLossFragments(
            isActive: stabilizationLatencyLine != nil,
            breakdown: breakdown
        )

        return """
        Onset — техническая информация о записи
        Сессия: \(formattedTimestamp)

        Реальные потери кадров (необратимо)
          Кодировщик backpressure — экран: \(breakdown.bpEncodeScreen)
          Кодировщик backpressure — камера: \(breakdown.bpEncodeCamera)
        \(stabilizationFragments.lossLines)  Захват — экран: \(breakdown.captureScreen)
          Захват — камера (видео): \(breakdown.captureCameraVideo)
          Захват — камера (аудио): \(breakdown.captureCameraAudio)

        Коалесция без потери содержимого (кадры воспроизведены, файл непрерывен)
          Нормализация CFR: \(counters.cfrNormalizationDrops)
          Hold-повторы кодировщика: \(holdDrops)

        Разбивка по источникам (все события, включая повторы без потери содержимого)
          Экран (захват): \(breakdown.captureScreen)
          Камера, видео (захват): \(breakdown.captureCameraVideo)
          Камера, аудио (захват): \(breakdown.captureCameraAudio)
          Кодировщик (экран): \(breakdown.encodeScreen)
          Кодировщик (камера): \(breakdown.encodeCamera)
        \(stabilizationFragments.breakdownLine)  Запись в файл: \(breakdown.writer)

        Острая деградация (всплеск backpressure): \(degradedLine)
        Основная причина: \(self.causeDescription(snapshot.dominantCause))
        \(stabilizationBlock)
        """
    }

    // MARK: - Coalescing arithmetic

    /// Hold repeats: all encoder events minus backpressure minus CFR normalization.
    /// Safe because encoder sources only emit encoderBackpressureDrops, encoderHoldDrops, and
    /// cfrNormalizationDrops — capture sources never emit CFR or hold events. The stabilization
    /// stage's events live in their own breakdown bucket and do not affect this arithmetic.
    nonisolated private static func holdDrops(breakdown: DropBreakdown, counters: DropCounters) -> Int {
        let encoderTotal = breakdown.encodeScreen + breakdown.encodeCamera
        let encoderBpTotal = breakdown.bpEncodeScreen + breakdown.bpEncodeCamera
        return encoderTotal - encoderBpTotal - counters.cfrNormalizationDrops
    }

    // MARK: - Stabilization loss fragments (#297 AC-3/AC-4)

    /// Two per-lane stabilization lines: `lossLines` (real-loss section, AC-4) and
    /// `breakdownLine` (per-source breakdown section). Both are the empty string when `isActive`
    /// is `false` — the AC-3 gate — so an OFF report carries no stabilization mention at all,
    /// byte-identical to the pre-#297 format.
    nonisolated private static func stabilizationLossFragments(
        isActive: Bool,
        breakdown: DropBreakdown
    )
    -> (lossLines: String, breakdownLine: String) {
        guard isActive else { return ("", "") }
        // Stage-internal drops (#297): slot eviction / pool exhaustion / render failure — the
        // fresh frame is lost (the tick is refilled by a downstream hold-repeat).
        let stageDrops = breakdown.stabilizeCamera - breakdown.bpStabilizeCamera
        let lossLines = "  Стабилизация — этап (камера): \(stageDrops)\n"
            + "  Стабилизация — backpressure на выходе (камера): \(breakdown.bpStabilizeCamera)\n"
        let breakdownLine = "  Стабилизация (камера): \(breakdown.stabilizeCamera)\n"
        return (lossLines, breakdownLine)
    }

    // MARK: - Stabilization block (#297 AC-4/AC-8)

    /// Builds the optional trailing stabilization block: present only when the stage ran
    /// (`latencyLine != nil`); the bypass line always accompanies the latency line.
    nonisolated private static func stabilizationBlock(
        bypassAtSeconds: Double?,
        latencyLine: String?
    )
    -> String {
        guard let latencyLine else { return "" }
        return self.bypassLine(bypassAtSeconds) + "\n" + latencyLine + "\n"
    }

    /// Renders the stabilization bypass line (#297 AC-4): the transition time in whole seconds
    /// from session start, or an explicit "no bypass" statement.
    nonisolated static func bypassLine(_ bypassAtSeconds: Double?) -> String {
        if let bypassAtSeconds {
            "Стабилизация камеры: отключена на \(Int(bypassAtSeconds.rounded()))-й секунде записи (перегруз)"
        } else {
            "Стабилизация камеры: переход в bypass: нет"
        }
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

        case .stabilizeCamera:
            "стабилизация камеры (backpressure на выходе этапа)"
        }
    }
}
