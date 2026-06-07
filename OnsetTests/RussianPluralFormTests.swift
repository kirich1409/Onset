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
// Domain-phrase tests (AC-9 alert message) live in PostStopAlertTests.swift — PostStopAlertMessageTests.
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

    @Test("13 → many form (teen exception: ends in 3 but also in 13)")
    func count13_selectsMany() {
        let result = RussianPluralForm.select(count: 13, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("14 → many form (teen exception: ends in 4 but also in 14)")
    func count14_selectsMany() {
        let result = RussianPluralForm.select(count: 14, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }

    @Test("113 → many form (teen exception: ends in 13)")
    func count113_selectsMany() {
        let result = RussianPluralForm.select(count: 113, one: "кадр", few: "кадра", many: "кадров")
        #expect(result == "кадров")
    }
}
