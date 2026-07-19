import Foundation
@testable import Onset
import Testing

@Suite("EngineBudgetCap.budgetCap(for:codec:)")
struct EngineBudgetCapTierTests {
    @Test("budgetCap(.m3Max) is 622_080_000 (seeded floor, #281)")
    func budgetCap_m3Max_value() {
        #expect(EngineBudgetCap.budgetCap(for: .m3Max, codec: .hevc).maxPixelsPerSecond == 622_080_000)
    }

    @Test("budgetCap(.uncalibrated) is 248_832_000 (safe-low)")
    func budgetCap_uncalibrated_value() {
        #expect(EngineBudgetCap.budgetCap(for: .uncalibrated, codec: .hevc).maxPixelsPerSecond == 248_832_000)
    }

    @Test("never-inherit (AC-Q9) — no tier's budget exceeds the dynamic .m3Max reference")
    func budgetCap_neverExceedsM3Max_dynamic() {
        let reference = EngineBudgetCap.budgetCap(for: .m3Max, codec: .hevc).maxPixelsPerSecond
        for tier in ChipTier.allCases {
            #expect(EngineBudgetCap.budgetCap(for: tier, codec: .hevc).maxPixelsPerSecond <= reference)
        }
    }

    @Test("seeded state — .m3Max is strictly greater than .uncalibrated")
    func budgetCap_m3Max_strictlyGreaterThan_uncalibrated() {
        let m3Max = EngineBudgetCap.budgetCap(for: .m3Max, codec: .hevc).maxPixelsPerSecond
        let uncalibrated = EngineBudgetCap.budgetCap(for: .uncalibrated, codec: .hevc).maxPixelsPerSecond
        #expect(m3Max > uncalibrated)
    }

    @Test("AC-Q7 — safe-low still fits 1080p60 screen + 1080p30 camera")
    func budgetCap_uncalibrated_fitsRecordableCombo() {
        let screen = SourceDimensions(width: 1920, height: 1080, fps: 60)
        let camera = SourceDimensions(width: 1920, height: 1080, fps: 30)
        #expect(EngineBudgetCap.budgetCap(for: .uncalibrated, codec: .hevc).fits(screen: screen, camera: camera))
    }
}
