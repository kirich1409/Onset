// RussianPluralFormTests.swift
// OnsetTests
//
// Swift Testing suite for RussianPluralForm — Russian pluralization helper.
//
// Covers the three CLDR plural categories for Russian:
//   one  — ends in 1 (not 11): 1, 21, 101
//   few  — ends in 2–4 (not 12–14): 2, 22, 112 (112 ends in 12 → many, not few; covered explicitly)
//   many — 0, 5–20, 11–14, and the teen exceptions: 11, 12, 100, 111
//
// Also covers droppedFrames(count:) phrase builder (AC-9 alert message).
//
@testable import Onset
import Testing

// MARK: - RussianPluralForm.select Tests

@Suite("RussianPluralForm.select — plural category selection")
struct RussianPluralFormSelectTests {
    // MARK: - one (ends in 1, not 11)

    @Test("1 → one form")
    func count1_selectsOne() {
        let result = RussianPluralForm.select(count: 1, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадр")
    }

    @Test("21 → one form (ends in 1, not 11)")
    func count21_selectsOne() {
        let result = RussianPluralForm.select(count: 21, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадр")
    }

    @Test("101 → one form (ends in 1, not 11)")
    func count101_selectsOne() {
        let result = RussianPluralForm.select(count: 101, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадр")
    }

    // MARK: - few (ends in 2–4, not 12–14)

    @Test("2 → few form")
    func count2_selectsFew() {
        let result = RussianPluralForm.select(count: 2, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадра")
    }

    @Test("22 → few form (ends in 2, not 12)")
    func count22_selectsFew() {
        let result = RussianPluralForm.select(count: 22, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадра")
    }

    // MARK: - many (0, 5–20, 11–14, and teen exceptions)

    @Test("5 → many form")
    func count5_selectsMany() {
        let result = RussianPluralForm.select(count: 5, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("11 → many form (teen exception: ends in 1 but also in 11)")
    func count11_selectsMany() {
        let result = RussianPluralForm.select(count: 11, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("100 → many form (ends in 0)")
    func count100_selectsMany() {
        let result = RussianPluralForm.select(count: 100, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("111 → many form (teen exception: ends in 11)")
    func count111_selectsMany() {
        let result = RussianPluralForm.select(count: 111, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("112 → many form (teen exception: ends in 12, not few)")
    func count112_selectsMany() {
        let result = RussianPluralForm.select(count: 112, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }
}

// MARK: - RussianPluralForm.droppedFrames Tests

@Suite("RussianPluralForm.droppedFrames — AC-9 alert phrase builder")
struct RussianPluralFormDroppedFramesTests {
    @Test("1 → Пропущен 1 кадр — возможны рывки.")
    func count1_singleFramePhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 1) == "Пропущен 1 кадр — возможны рывки.")
    }

    @Test("2 → Пропущено 2 кадра — возможны рывки.")
    func count2_fewFramesPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 2) == "Пропущено 2 кадра — возможны рывки.")
    }

    @Test("5 → Пропущено 5 кадров — возможны рывки.")
    func count5_manyFramesPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 5) == "Пропущено 5 кадров — возможны рывки.")
    }

    @Test("11 → Пропущено 11 кадров — возможны рывки. (teen exception)")
    func count11_teenExceptionPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 11) == "Пропущено 11 кадров — возможны рывки.")
    }

    @Test("21 → Пропущен 21 кадр — возможны рывки. (one form)")
    func count21_oneFormPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 21) == "Пропущен 21 кадр — возможны рывки.")
    }

    @Test("22 → Пропущено 22 кадра — возможны рывки. (few form)")
    func count22_fewFormPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 22) == "Пропущено 22 кадра — возможны рывки.")
    }

    @Test("100 → Пропущено 100 кадров — возможны рывки.")
    func count100_hundredPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 100) == "Пропущено 100 кадров — возможны рывки.")
    }

    @Test("101 → Пропущен 101 кадр — возможны рывки. (ends in 1)")
    func count101_oneFormPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 101) == "Пропущен 101 кадр — возможны рывки.")
    }

    @Test("111 → Пропущено 111 кадров — возможны рывки. (teen exception ends in 11)")
    func count111_teenExceptionPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 111) == "Пропущено 111 кадров — возможны рывки.")
    }

    @Test("112 → Пропущено 112 кадров — возможны рывки. (teen exception ends in 12)")
    func count112_teenExceptionPhrase() {
        #expect(RussianPluralForm.droppedFrames(count: 112) == "Пропущено 112 кадров — возможны рывки.")
    }
}
