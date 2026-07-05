// RecordingViewTests.swift
// OnsetTests
//
// Swift Testing suite for RecordingView display-logic (#37).
//
// Tests the pure static mappers in `RecordingDisplayMapper` and `ElapsedFormatter`.
// No SwiftUI rendering — all assertions are against value returns, making these fast L2 tests.
//
// The drop pill was removed (frame-loss is now persisted as an on-disk technical report, not shown
// in the recording window), so the pill-text / pill-a11y mapper suites are gone; the degradation
// status row is kept and still tested below.
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

    // MARK: State word — gendered Russian forms

    @Test("Live masculine gives активен")
    func liveWordMasculine() {
        #expect(RecordingDisplayMapper.stateWord(isLive: true, gender: .masculine) == "активен")
    }

    @Test("Live feminine gives активна")
    func liveWordFeminine() {
        #expect(RecordingDisplayMapper.stateWord(isLive: true, gender: .feminine) == "активна")
    }

    @Test("Revoked masculine gives остановлен")
    func revokedWordMasculine() {
        #expect(RecordingDisplayMapper.stateWord(isLive: false, gender: .masculine) == "остановлен")
    }

    @Test("Revoked feminine gives остановлена")
    func revokedWordFeminine() {
        #expect(RecordingDisplayMapper.stateWord(isLive: false, gender: .feminine) == "остановлена")
    }

    // MARK: Value text

    @Test("Live masculine source value text is unchanged")
    func liveValueTextMasculine() {
        let result = RecordingDisplayMapper.checklistRowValueText(
            value: "3840×2160",
            isLive: true,
            gender: .masculine
        )
        #expect(result == "3840×2160")
    }

    @Test("Live feminine source value text is unchanged")
    func liveValueTextFeminine() {
        let result = RecordingDisplayMapper.checklistRowValueText(
            value: "MX Brio · 1920×1080",
            isLive: true,
            gender: .feminine
        )
        #expect(result == "MX Brio · 1920×1080")
    }

    @Test("Revoked masculine source appends · остановлен")
    func revokedValueTextMasculine() {
        let result = RecordingDisplayMapper.checklistRowValueText(
            value: "3840×2160",
            isLive: false,
            gender: .masculine
        )
        #expect(result == "3840×2160 · остановлен")
    }

    @Test("Revoked feminine source appends · остановлена")
    func revokedValueTextFeminine() {
        let result = RecordingDisplayMapper.checklistRowValueText(
            value: "MX Brio · 1920×1080",
            isLive: false,
            gender: .feminine
        )
        #expect(result == "MX Brio · 1920×1080 · остановлена")
    }

    @Test("Live source with empty value passes through unchanged")
    func liveEmptyValue() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "", isLive: true, gender: .masculine)
        #expect(result.isEmpty)
    }

    @Test("Revoked feminine source with empty value shows only suffix")
    func revokedEmptyValueFeminine() {
        let result = RecordingDisplayMapper.checklistRowValueText(value: "", isLive: false, gender: .feminine)
        #expect(result == " · остановлена")
    }

    // MARK: Accessibility label

    @Test("Live feminine accessibility label includes value and активна")
    func accessibilityLabelLiveFeminine() {
        let result = RecordingDisplayMapper.checklistRowAccessibilityLabel(
            label: "Камера",
            value: "MX Brio · 1920×1080",
            isLive: true,
            gender: .feminine
        )
        #expect(result == "Камера — MX Brio · 1920×1080 — активна")
    }

    @Test("Revoked feminine accessibility label includes value and остановлена")
    func accessibilityLabelRevokedFeminine() {
        let result = RecordingDisplayMapper.checklistRowAccessibilityLabel(
            label: "Камера",
            value: "MX Brio · 1920×1080",
            isLive: false,
            gender: .feminine
        )
        #expect(result == "Камера — MX Brio · 1920×1080 — остановлена")
    }

    @Test("Live masculine accessibility label includes value and активен")
    func accessibilityLabelLiveMasculine() {
        let result = RecordingDisplayMapper.checklistRowAccessibilityLabel(
            label: "Экран",
            value: "3840×2160",
            isLive: true,
            gender: .masculine
        )
        #expect(result == "Экран — 3840×2160 — активен")
    }

    @Test("Revoked masculine accessibility label includes value and остановлен")
    func accessibilityLabelRevokedMasculine() {
        let result = RecordingDisplayMapper.checklistRowAccessibilityLabel(
            label: "Микрофон",
            value: "MacBook Pro",
            isLive: false,
            gender: .masculine
        )
        #expect(result == "Микрофон — MacBook Pro — остановлен")
    }
}

// MARK: - RecordingDisplayMapper — Device-lost banner (#261)

@Suite("RecordingDisplayMapper device-lost banner")
@MainActor
struct DeviceLostBannerMapperTests {
    @Test("All sources live returns no banner text")
    func allLiveReturnsNil() {
        #expect(RecordingDisplayMapper.deviceLostBannerText(sourceLiveness: .allLive) == nil)
    }

    @Test("Camera lost names the camera with feminine wording")
    func cameraLost() {
        let result = RecordingDisplayMapper.deviceLostBannerText(
            sourceLiveness: .init(screen: true, camera: false, microphone: true)
        )
        #expect(result == "Камера отключена — запись продолжается без неё")
    }

    @Test("Screen lost names the screen with masculine wording")
    func screenLost() {
        let result = RecordingDisplayMapper.deviceLostBannerText(
            sourceLiveness: .init(screen: false, camera: true, microphone: true)
        )
        #expect(result == "Экран отключён — запись продолжается без него")
    }

    @Test("Camera and microphone lost together joins with и and plural wording")
    func cameraAndMicrophoneLost() {
        let result = RecordingDisplayMapper.deviceLostBannerText(
            sourceLiveness: .init(screen: true, camera: false, microphone: false)
        )
        #expect(result == "Камера и микрофон отключены — запись продолжается без них")
    }

    @Test("All three sources lost joins all with и")
    func allThreeLost() {
        let result = RecordingDisplayMapper.deviceLostBannerText(
            sourceLiveness: .init(screen: false, camera: false, microphone: false)
        )
        #expect(result == "Экран и камера и микрофон отключены — запись продолжается без них")
    }
}
