// HEVCProfileLevel+VideoToolbox.swift
// Onset
//
// Shared VideoToolbox mapping for the pure-Swift `HEVCProfileLevel` enum.
//
// EXTRACTED from CapabilityProbe.swift (U3 of #31): the `vtProfileLevel` mapping was
// previously a `fileprivate` member of CapabilityProbe.swift. The VideoEncoder actor (U3)
// needs the same mapping to set `kVTCompressionPropertyKey_ProfileLevel`, so the mapping
// is hoisted into one shared `internal` extension to avoid duplication. CapabilityProbe and
// VideoEncoder now use this single source of truth.
//
// Isolation: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, the computed property is
// explicitly `nonisolated` so it is usable from the `nonisolated` CapabilityProbe enum and
// from the `VideoEncoder` actor's session setup alike.

import VideoToolbox

// MARK: - HEVCProfileLevel + VideoToolbox mapping

extension HEVCProfileLevel {
    /// The corresponding `kVTProfileLevel_HEVC_*` constant for `VTSessionSetProperty`.
    ///
    /// Maps the pure-Swift `HEVCProfileLevel` (declared in `RecordingPolicyTypes.swift`,
    /// framework-free) to the VideoToolbox `CFString` constant. This is the single place
    /// the VT-constant mapping lives — both `CapabilityProbe` (HW pre-flight) and
    /// `VideoEncoder` (real session) read it.
    nonisolated var vtProfileLevel: CFString {
        switch self {
        case .mainAutoLevel:
            kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }
}
