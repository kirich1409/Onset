@testable import Onset
import Testing

// MARK: - ChipTier synthesis tests

/// No `@MainActor` annotation: `OnsetTests` is not default-MainActor-isolated, so this suite is
/// already `nonisolated` — it exercises the synthesized `Equatable`/`CaseIterable` witnesses off
/// the main actor without any special harness.
@Suite("ChipTier")
struct ChipTierTests {
    @Test("m3Max == m3Max")
    func m3Max_equalsItself() {
        #expect(ChipTier.m3Max == .m3Max)
    }

    @Test("m3Max != uncalibrated")
    func m3Max_notEqualUncalibrated() {
        #expect(ChipTier.m3Max != .uncalibrated)
    }

    @Test("allCases has exactly the two documented tiers")
    func allCases_hasTwoTiers() {
        #expect(ChipTier.allCases.count == 2)
    }
}
