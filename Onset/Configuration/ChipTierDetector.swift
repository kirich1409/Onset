import Foundation
import os

// MARK: - ChipTierDetector

/// Detects the host chip's `ChipTier` from the CPU brand string.
///
/// Split into a pure classifier (`chipTier(forBrandString:)`, fully unit-testable, no
/// hardware) and an impure reader (`detectChipTier()`, `sysctlbyname` on
/// `machdep.cpu.brand_string`). Mirrors `CapabilityProbe`'s `nonisolated enum` namespace +
/// `unsafe` C-interop + `Logger` pattern.
nonisolated enum ChipTierDetector {
    // MARK: - Logger

    private static let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "ChipTierDetector"
    )

    // MARK: - Pure classification

    /// Classifies a CPU brand string into a `ChipTier`, purely and totally.
    ///
    /// Only a string identifying Apple M3 Max (case/space-normalized, e.g. `"Apple M3 Max"`)
    /// maps to `.m3Max`. Every other input — other Apple chips ("Apple M3", "Apple M3 Pro",
    /// "Apple M2 Max", …), empty, garbage, non-Apple — maps to `.uncalibrated`. Never crashes;
    /// never resolves anything not-provably-M3-Max to a higher tier.
    ///
    /// - Parameter brandString: The raw `machdep.cpu.brand_string` value (or any candidate).
    /// - Returns: `.m3Max` only for a confirmed M3 Max brand string, `.uncalibrated` otherwise.
    nonisolated static func chipTier(forBrandString brandString: String) -> ChipTier {
        let normalized = brandString
            .lowercased()
            .split(separator: " ")
            .joined(separator: " ")
        return normalized == "apple m3 max" ? .m3Max : .uncalibrated
    }

    // MARK: - Impure detection

    /// Reads `machdep.cpu.brand_string` via `sysctlbyname` and delegates to the pure
    /// classifier. `hw.model` is intentionally not used — it returns a model code (e.g.
    /// `"Mac15,10"`) the brand-string parser cannot read.
    ///
    /// Any read failure (sysctl error, zero-length result) resolves to `.uncalibrated` —
    /// safe-low, never a crash.
    ///
    /// - Returns: The detected `ChipTier`, or `.uncalibrated` on any read failure.
    nonisolated static func detectChipTier() -> ChipTier {
        var size = 0
        // `unsafe` required under SWIFT_STRICT_MEMORY_SAFETY = YES: sysctlbyname takes raw
        // pointer out-parameters.
        let sizeQueryStatus = unsafe sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard sizeQueryStatus == 0, size > 0 else {
            Self.logger.warning("sysctlbyname size query failed or returned 0 — uncalibrated")
            return .uncalibrated
        }

        var buffer = [CChar](repeating: 0, count: size)
        // `unsafe` required at both the buffer-pointer closure and the inner sysctlbyname call.
        let readStatus = unsafe buffer.withUnsafeMutableBufferPointer { pointer in
            unsafe sysctlbyname("machdep.cpu.brand_string", pointer.baseAddress, &size, nil, 0)
        }
        guard readStatus == 0 else {
            Self.logger.warning("sysctlbyname read failed — uncalibrated")
            return .uncalibrated
        }

        // The sysctl-reported `size` includes the NUL terminator — trim it before decoding.
        let trimmed = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // `String(decoding:as:)`, not the deprecated `String(cString:)` (deprecation would fail
        // the warnings-as-errors build). This is not a `Data`->`String` conversion — the
        // optional_data_string_conversion rule's failable-init concern doesn't apply to `[UInt8]`.
        // swiftlint:disable:next optional_data_string_conversion
        let raw = String(decoding: trimmed, as: UTF8.self)
        Self.logger.info("machdep.cpu.brand_string = \(raw)")

        return self.chipTier(forBrandString: raw)
    }
}
