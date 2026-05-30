import Domain
import Foundation

// MARK: - StreamBudget

/// The multi-stream encode budget for a given `ChipTier`.
///
/// Defines how many simultaneous hardware encode sessions the chip tier can sustain
/// at the given reference resolutions. There is no public VideoToolbox API for this —
/// the budgets are derived from Apple's published hardware specs and empirical testing.
///
/// Priority rule (architecture.md §Capability-модель):
///   - `VTCopyVideoEncoderList` probe is **ground truth for single-stream availability**.
///   - `CapabilityMatrix` is the **sole source for multi-stream session count estimates**.
///
/// MJPEG decode is a separate hardware engine on Apple Silicon; `mjpegDecodeSlots`
/// counts how many simultaneous hardware MJPEG decode sessions are supported alongside
/// encode sessions.
public struct StreamBudget: Sendable, Equatable {
    /// Maximum number of simultaneous hardware video encode sessions.
    public let maxHardwareEncodeSessions: Int
    /// Maximum simultaneous hardware MJPEG decode sessions (camera input).
    public let mjpegDecodeSlots: Int
    /// Maximum combined screen-capture pixel throughput (in megapixels per second).
    /// Used by the Validator to reject configurations that would exceed the budget.
    public let maxScreenCaptureMpps: Double

    public init(
        maxHardwareEncodeSessions: Int,
        mjpegDecodeSlots: Int,
        maxScreenCaptureMpps: Double
    ) {
        self.maxHardwareEncodeSessions = maxHardwareEncodeSessions
        self.mjpegDecodeSlots = mjpegDecodeSlots
        self.maxScreenCaptureMpps = maxScreenCaptureMpps
    }
}

// MARK: - CapabilityMatrix

/// Static lookup table mapping `ChipTier` → multi-stream `StreamBudget`.
///
/// Pure data: no I/O, no side effects, fully unit-testable without hardware.
///
/// ### Budget rationale
/// | Tier    | Encode engines | MJPEG decode | Notes |
/// |---------|---------------|--------------|-------|
/// | base    | 1             | 1            | Single media engine |
/// | pro     | 2             | 2            | Dual media engine |
/// | max     | 2             | 2            | Same dual-engine as Pro; higher CPU/bandwidth headroom |
/// | ultra   | 4             | 4            | Two Max dies fused; empirically 4 independent encode sessions |
/// | unknown | 1             | 1            | Conservative fallback — treat as single-engine |
///
/// Budgets are conservative: a `base` has one media engine in practice, but sustained
/// 4K encode at full bandwidth may saturate memory. Use the Validator's margin (see
/// `capability-and-settings/spec.md §Decisions`) to gate configs that push the limit.
public enum CapabilityMatrix {

    // MARK: - Public API

    /// Returns the multi-stream `StreamBudget` for `tier`.
    ///
    /// - Parameter tier: The `ChipTier` of the current device.
    /// - Returns: The `StreamBudget` for that tier. Never throws; `.unknown` returns a
    ///   conservative single-engine budget rather than crashing.
    public static func budget(for tier: ChipTier) -> StreamBudget {
        switch tier {
        case .base:
            return StreamBudget(
                maxHardwareEncodeSessions: 1,
                mjpegDecodeSlots: 1,
                maxScreenCaptureMpps: 248.83  // 3840×2160×30 / 1_000_000 ≈ 248.83 (4K@30 × 1 stream)
            )
        case .pro:
            return StreamBudget(
                maxHardwareEncodeSessions: 2,
                mjpegDecodeSlots: 2,
                maxScreenCaptureMpps: 497.66  // 3840×2160×30 / 1_000_000 × 2 streams ≈ 497.66
            )
        case .max:
            // Same dual media engine as Pro; more P-cores and memory bandwidth allow
            // higher sustained throughput before thermal throttling.
            return StreamBudget(
                maxHardwareEncodeSessions: 2,
                mjpegDecodeSlots: 2,
                maxScreenCaptureMpps: 497.66  // 3840×2160×30 / 1_000_000 × 2 streams ≈ 497.66
            )
        case .ultra:
            // Two Max dies fused; four independent media engines confirmed on M1/M2 Ultra.
            return StreamBudget(
                maxHardwareEncodeSessions: 4,
                mjpegDecodeSlots: 4,
                maxScreenCaptureMpps: 995.33  // 3840×2160×30 / 1_000_000 × 4 streams ≈ 995.33
            )
        case .unknown:
            // Conservative single-engine fallback. Applied whenever sysctl cannot classify
            // the chip brand string (virtual machines, future silicon not yet in the matrix).
            return StreamBudget(
                maxHardwareEncodeSessions: 1,
                mjpegDecodeSlots: 1,
                maxScreenCaptureMpps: 248.83  // 3840×2160×30 / 1_000_000 ≈ 248.83 (4K@30 × 1 stream)
            )
        }
    }

    // MARK: - Pure classification helper

    /// Classifies an Apple Silicon chip tier from a `machdep.cpu.brand_string` value.
    ///
    /// Extracted as a `static func` so unit tests can drive it without touching live sysctl.
    /// Matching strategy:
    ///   1. Require the string contains "Apple" (reject Intel/other brands as `.unknown`).
    ///   2. Suffix token search: "Ultra" → `.ultra`, "Max" → `.max`, "Pro" → `.pro`.
    ///   3. Bare "M\d" or "M\d+" with no tier suffix → `.base`.
    ///   4. Anything else → `.unknown`.
    ///
    /// Case-insensitive for forward-compatibility with potential casing changes in future SDKs.
    ///
    /// - Parameter brand: The brand string from `machdep.cpu.brand_string` sysctl,
    ///   e.g. `"Apple M3 Max"`, `"Apple M2"`, `"Apple M4 Ultra"`.
    /// - Returns: The inferred `ChipTier`.
    public static func classifyChipTier(brand: String) -> ChipTier {
        let lower = brand.lowercased()
        guard lower.contains("apple") else {
            // Non-Apple silicon (Intel, virtual machine, etc.) — conservative fallback.
            return .unknown
        }
        // Match the tier suffix token. Order matters: check "ultra" before "max" before "pro"
        // because a hypothetical future tier like "ultra pro" should still resolve to ultra.
        if lower.contains("ultra") { return .ultra }
        if lower.contains("max") { return .max }
        if lower.contains("pro") { return .pro }
        // No tier suffix — expect a bare "Apple M<n>" string → base tier.
        // A minimal guard: require the brand string to contain "m" (matches "Apple M1" etc.)
        if lower.contains(" m") { return .base }
        // Unrecognized Apple chip format — conservative fallback.
        return .unknown
    }
}
