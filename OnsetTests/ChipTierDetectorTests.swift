@testable import Onset
import Testing

// MARK: - ChipTierDetector parse matrix tests

/// No `@MainActor` annotation: `OnsetTests` is not default-MainActor-isolated, so this suite is
/// already `nonisolated` — it exercises the pure `chipTier(forBrandString:)` classifier off the
/// main actor without any special harness. `detectChipTier()`'s impure sysctl path is exercised
/// on real hardware in T-6 — not covered here.
@Suite("ChipTierDetector")
struct ChipTierDetectorTests {
    @Test("Apple M3 Max variants classify as m3Max", arguments: [
        "Apple M3 Max",
        "apple m3 max",
        "APPLE M3 MAX",
        "Apple  M3  Max",
    ])
    func m3MaxVariant_classifiesAsM3Max(brandString: String) {
        #expect(ChipTierDetector.chipTier(forBrandString: brandString) == .m3Max)
    }

    @Test("Other Apple chips classify as uncalibrated", arguments: [
        "Apple M3",
        "Apple M3 Pro",
        "Apple M2 Max",
        "Apple M2 Ultra",
        "Apple M1",
        "Apple M4 Max",
    ])
    func otherAppleChip_classifiesAsUncalibrated(brandString: String) {
        #expect(ChipTierDetector.chipTier(forBrandString: brandString) == .uncalibrated)
    }

    @Test("Non-Apple, empty, and garbage input classify as uncalibrated", arguments: [
        "",
        "garbage",
        "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz",
        "M3 Max",
        "Apple M3 Max Pro",
        "🍎 M3 Max",
    ])
    func nonAppleOrGarbage_classifiesAsUncalibrated(brandString: String) {
        #expect(ChipTierDetector.chipTier(forBrandString: brandString) == .uncalibrated)
    }
}
