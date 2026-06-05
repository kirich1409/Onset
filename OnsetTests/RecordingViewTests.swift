// RecordingViewTests.swift
// OnsetTests
//
// Swift Testing suite for RecordingView display-logic (#37).
//
// Tests the pure static mappers in `RecordingDisplayMapper` and `ElapsedFormatter`.
// No SwiftUI rendering — all assertions are against value returns, making these fast L2 tests.
//
@testable import Onset
import SwiftUI
import Testing

// MARK: - ElapsedFormatter Tests

@Suite("ElapsedFormatter")
@MainActor
struct ElapsedFormatterTests {
    @Test("Zero seconds formats as 00:00")
    func zeroSeconds() {
        #expect(ElapsedFormatter.string(from: 0) == "00:00")
    }

    @Test("59 seconds formats as 00:59")
    func fiftyNineSeconds() {
        #expect(ElapsedFormatter.string(from: 59) == "00:59")
    }

    @Test("60 seconds rolls over to 01:00")
    func sixtySeconds() {
        #expect(ElapsedFormatter.string(from: 60) == "01:00")
    }

    @Test("257 seconds formats as 04:17")
    func twoHundredFiftySeven() {
        #expect(ElapsedFormatter.string(from: 257) == "04:17")
    }

    @Test("3599 seconds is 59:59 (no hours)")
    func threeThousandFiveHundredNinetyNine() {
        #expect(ElapsedFormatter.string(from: 3599) == "59:59")
    }

    @Test("3600 seconds is 1:00:00 (hour rollover)")
    func oneHour() {
        #expect(ElapsedFormatter.string(from: 3600) == "1:00:00")
    }

    @Test("3661 seconds is 1:01:01")
    func oneHourOneMinuteOneSecond() {
        #expect(ElapsedFormatter.string(from: 3661) == "1:01:01")
    }

    @Test("Negative seconds clamp to 00:00")
    func negativeSeconds() {
        #expect(ElapsedFormatter.string(from: -5) == "00:00")
    }
}

// MARK: - RecordingDisplayMapper — Status

@Suite("RecordingDisplayMapper status")
@MainActor
struct RecordingDisplayMapperStatusTests {
    @Test("Normal state shows ИДЁТ ЗАПИСЬ")
    func normalStatusText() {
        #expect(RecordingDisplayMapper.statusText(for: .normal) == "ИДЁТ ЗАПИСЬ")
    }

    @Test("Degraded state shows ЗАПИСЬ · ДЕГРАДАЦИЯ")
    func degradedStatusText() {
        #expect(RecordingDisplayMapper.statusText(for: .degraded) == "ЗАПИСЬ · ДЕГРАДАЦИЯ")
    }

    @Test("Dot is red for normal state")
    func normalDotColorIsRed() {
        #expect(RecordingDisplayMapper.dotColor(for: .normal) == .red)
    }

    @Test("Dot is red for degraded state (same red dot per mockup)")
    func degradedDotColorIsRed() {
        #expect(RecordingDisplayMapper.dotColor(for: .degraded) == .red)
    }

    @Test("Status text color is red for normal")
    func normalTextColorIsRed() {
        #expect(RecordingDisplayMapper.statusTextColor(for: .normal) == .red)
    }

    @Test("Status text color is orange for degraded")
    func degradedTextColorIsOrange() {
        #expect(RecordingDisplayMapper.statusTextColor(for: .degraded) == .orange)
    }
}

// MARK: - RecordingDisplayMapper — Drop Pill

@Suite("RecordingDisplayMapper drop pill")
@MainActor
struct RecordingDisplayMapperPillTests {
    private func drops(backpressure: Int = 0, capture: Int = 0, cfr: Int = 0) -> DropCounters {
        DropCounters(
            encoderBackpressureDrops: backpressure,
            captureDrops: capture,
            cfrNormalizationDrops: cfr
        )
    }

    @Test("Normal state pill shows 0 dropped frames")
    func normalPillZero() {
        let text = RecordingDisplayMapper.pillText(state: .normal, drops: self.drops())
        #expect(text == "0 пропущенных кадров")
    }

    @Test("Normal state pill shows exact backpressure count")
    func normalPillNonZero() {
        let text = RecordingDisplayMapper.pillText(state: .normal, drops: self.drops(backpressure: 5))
        #expect(text == "5 пропущенных кадров")
    }

    @Test("Normal state pill ignores captureDrops")
    func normalPillIgnoresCaptureDrops() {
        let text = RecordingDisplayMapper.pillText(state: .normal, drops: self.drops(backpressure: 0, capture: 99))
        #expect(text == "0 пропущенных кадров")
    }

    @Test("Degraded state pill shows Пропущено N кадров · диск")
    func degradedPillText() {
        let text = RecordingDisplayMapper.pillText(state: .degraded, drops: self.drops(backpressure: 128))
        #expect(text == "Пропущено 128 кадров · диск")
    }

    @Test("Degraded state pill background is orange")
    func degradedPillBackground() {
        #expect(RecordingDisplayMapper.pillBackground(for: .degraded) == .orange)
    }

    @Test("Normal state pill background is not orange")
    func normalPillBackgroundIsNotOrange() {
        #expect(RecordingDisplayMapper.pillBackground(for: .normal) != .orange)
    }

    @Test("Degraded pill text color is white")
    func degradedPillTextColor() {
        #expect(RecordingDisplayMapper.pillTextColor(for: .degraded) == .white)
    }

    @Test("Degraded pill dot is orange")
    func degradedPillDot() {
        #expect(RecordingDisplayMapper.pillDotColor(for: .degraded) == .orange)
    }
}

// MARK: - RecordingDisplayMapper — Checklist row liveness (#39 / AC-12)

@Suite("RecordingDisplayMapper checklist liveness")
@MainActor
struct ChecklistLivenessMapperTests {
    // MARK: Icon

    @Test("Live source shows checkmark icon")
    func liveIcon() {
        #expect(RecordingDisplayMapper.checklistRowIcon(isLive: true) == "checkmark")
    }

    @Test("Revoked source shows xmark icon")
    func revokedIcon() {
        #expect(RecordingDisplayMapper.checklistRowIcon(isLive: false) == "xmark")
    }

    // MARK: Icon color

    @Test("Live source icon is green")
    func liveIconColor() {
        #expect(RecordingDisplayMapper.checklistRowIconColor(isLive: true) == .green)
    }

    @Test("Revoked source icon is red")
    func revokedIconColor() {
        #expect(RecordingDisplayMapper.checklistRowIconColor(isLive: false) == .red)
    }

    // MARK: Value text

    @Test("Live source value text is unchanged")
    func liveValueText() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "MX Brio · 1920×1080", isLive: true)
        #expect(result == "MX Brio · 1920×1080")
    }

    @Test("Revoked source value text appends · остановлен")
    func revokedValueText() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "MX Brio · 1920×1080", isLive: false)
        #expect(result == "MX Brio · 1920×1080 · остановлен")
    }

    @Test("Live source with empty value passes through unchanged")
    func liveEmptyValue() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "", isLive: true)
        #expect(result.isEmpty)
    }

    @Test("Revoked source with empty value shows only suffix")
    func revokedEmptyValue() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "", isLive: false)
        #expect(result == " · остановлен")
    }

    // MARK: Value text color

    @Test("Live source value text color is .secondary")
    func liveValueTextColor() {
        #expect(RecordingDisplayMapper.checklistRowValueTextColor(isLive: true) == .secondary)
    }

    @Test("Revoked source value text color is dimmed .secondary")
    func revokedValueTextColor() {
        let expected = Color.secondary.opacity(RecordingDisplayMapper.revokedValueTextOpacity)
        #expect(RecordingDisplayMapper.checklistRowValueTextColor(isLive: false) == expected)
    }
}
