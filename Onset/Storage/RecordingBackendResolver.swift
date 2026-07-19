import Foundation
import os

// MARK: - Logger

/// Shared `os.Logger` for `RecordingBackendResolver` warning diagnostics.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// Sendable by construction — `Logger` is a value type that captures no mutable state.
nonisolated let recordingBackendResolverLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingBackendResolver"
)

// MARK: - SupportedBackends

// TODO: migrate from per-stage Bool fields to a per-stage Set/Map when any stage
// gains a 2nd–3rd backend (Bool-per-stage stops scaling then).
/// A snapshot of which backend variants the current runtime environment supports.
///
/// Passed to `RecordingBackendResolver.resolve(persisted:supported:)` so the resolver
/// can fall back to `.live` for any backend that the host does not support, without
/// hard-coding those checks inside the resolver itself.
///
/// `allSupported` is the production default — all stages are available on supported hardware.
/// Tests construct instances with exactly one flag set to `false` to exercise the
/// known-but-unsupported fallback branch.
///
/// Declared `nonisolated` so that the resolver — a `nonisolated enum` — can accept this
/// type without a MainActor hop, matching the pattern of other pure value types in this project.
nonisolated struct SupportedBackends {
    /// Whether the live AVFoundation / ScreenCaptureKit capture backend is available.
    nonisolated let isSourceLiveSupported: Bool
    /// Whether the live VideoToolbox HEVC encoder backend is available.
    nonisolated let isEncoderLiveSupported: Bool
    /// Whether the live AVAssetWriter muxing backend is available.
    nonisolated let isWriterLiveSupported: Bool

    /// The production default — all backends are supported.
    ///
    /// Used by the composition root when no hardware restrictions apply.
    nonisolated static let allSupported = Self(
        isSourceLiveSupported: true,
        isEncoderLiveSupported: true,
        isWriterLiveSupported: true
    )
}

// MARK: - RecordingBackendResolver

/// Pure resolver that converts a persisted backend selection into a best-effort resolved
/// `ResolvedBackendSelection`.
///
/// Each pipeline stage (source / encoder / writer) is resolved independently:
/// - `nil` persisted value or `nil` raw string → `.live` (default, no warning).
/// - Non-nil raw string that does not match any known backend → `.live` + `warning` log.
/// - Known backend that is not currently supported → `.live` + `warning` log.
/// - Known and supported → the persisted value.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests and composition roots without an actor context.
/// The resolver touches no framework state or hardware — it is a pure function.
nonisolated enum RecordingBackendResolver {
    /// Resolves a persisted backend selection against the currently supported backends.
    ///
    /// - Parameters:
    ///   - persisted: The raw persisted selection from `UserDefaults`, or `nil` when
    ///     no selection has been stored (first launch, or after a clear).
    ///   - supported: A snapshot of which backends the current runtime environment supports.
    /// - Returns: A `ResolvedBackendSelection` where every stage is best-effort resolved,
    ///   falling back to `.live` even when `.live` is unsupported (a warning is logged).
    nonisolated static func resolve(
        persisted: PersistedBackendSelection?,
        supported: SupportedBackends
    )
    -> ResolvedBackendSelection {
        ResolvedBackendSelection(
            source: self.resolveSource(rawString: persisted?.source, supported: supported),
            encoder: self.resolveEncoder(rawString: persisted?.encoder, supported: supported),
            writer: self.resolveWriter(rawString: persisted?.writer, supported: supported)
        )
    }

    // MARK: - Per-stage resolution

    nonisolated private static func resolveSource(
        rawString: String?,
        supported: SupportedBackends
    )
    -> SourceBackend {
        guard let raw = rawString else {
            return .live
        }
        guard let parsed = SourceBackend(rawString: raw) else {
            recordingBackendResolverLogger.warning(
                "Unrecognised source backend '\(raw)' — falling back to .live"
            )
            return .live
        }
        switch parsed {
        case .live:
            if supported.isSourceLiveSupported {
                return .live
            } else {
                recordingBackendResolverLogger.warning(
                    "Source backend '\(raw)' is not supported on this system — falling back to .live"
                )
                return .live
            }
        }
    }

    nonisolated private static func resolveEncoder(
        rawString: String?,
        supported: SupportedBackends
    )
    -> EncoderBackend {
        guard let raw = rawString else {
            return .live
        }
        guard let parsed = EncoderBackend(rawString: raw) else {
            recordingBackendResolverLogger.warning(
                "Unrecognised encoder backend '\(raw)' — falling back to .live"
            )
            return .live
        }
        switch parsed {
        case .live:
            if supported.isEncoderLiveSupported {
                return .live
            } else {
                recordingBackendResolverLogger.warning(
                    "Encoder backend '\(raw)' is not supported on this system — falling back to .live"
                )
                return .live
            }
        }
    }

    nonisolated private static func resolveWriter(
        rawString: String?,
        supported: SupportedBackends
    )
    -> WriterBackend {
        guard let raw = rawString else {
            return .live
        }
        guard let parsed = WriterBackend(rawString: raw) else {
            recordingBackendResolverLogger.warning(
                "Unrecognised writer backend '\(raw)' — falling back to .live"
            )
            return .live
        }
        switch parsed {
        case .live:
            if supported.isWriterLiveSupported {
                return .live
            } else {
                recordingBackendResolverLogger.warning(
                    "Writer backend '\(raw)' is not supported on this system — falling back to .live"
                )
                return .live
            }
        }
    }
}
