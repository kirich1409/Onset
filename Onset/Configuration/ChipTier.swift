// MARK: - ChipTier

/// AC-Q4 calibration tier for the host chip's media engine throughput.
///
/// Only `.m3Max` carries an empirically calibrated budget (see
/// `EngineBudgetCap.budgetCap(for:codec:)`); every other chip — recognized or unknown — resolves
/// to `.uncalibrated`, a single conservative safe-low. Media-engine count cannot be inferred from
/// a marketing suffix (Apple Silicon Pro chips have one media engine, only Max has two, Ultra has
/// four), so no per-engine multiplier is derived here — each tier earns a higher budget only
/// through its own AC-Q4 sweep.
///
/// Relies on full compiler synthesis for `Equatable` and `CaseIterable` — no explicit `==`, no
/// explicit `allCases`. This is a deliberate deviation from the project's usual "enums need an
/// explicit `nonisolated ==`" pattern (see `Container`/`PermissionStatus`): a spike compiling this
/// exact shape under the project's strict-concurrency flags confirmed both witnesses are usable
/// from a `nonisolated` context, and — because `CaseIterable` pulls in an implicit `Hashable`
/// conformance — a separate `extension ChipTier: Equatable { }` would make the synthesized
/// `Hashable` witness `@MainActor` and fail to build. Fallback only if a future toolchain
/// regresses: add the witness inside the enum body, or use a plain `extension ChipTier { }` that
/// does not re-declare the conformance.
nonisolated enum ChipTier: Equatable, CaseIterable {
    /// Apple M3 Max — the AC-Q4-calibrated reference tier.
    case m3Max
    /// Every other chip, recognized or unknown — conservative safe-low until its own AC-Q4 sweep.
    case uncalibrated
}
