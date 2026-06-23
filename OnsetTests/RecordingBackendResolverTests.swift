import Foundation
@testable import Onset
import Testing

// MARK: - RecordingBackendResolverTests

/// L2 tests for `RecordingBackendResolver`.
///
/// Covers all four resolution branches applied independently to each pipeline stage:
/// 1. `persisted == nil` → all stages resolve to `.live`.
/// 2. Unknown raw string in one stage → that stage falls back to `.live`.
/// 3. Known backend string, but the matching `SupportedBackends` flag is `false`
///    → that stage falls back to `.live`.
/// 4. Known and supported → resolves to the persisted value.
///
/// `@MainActor` is required because `PersistedBackendSelection` and the backend enums
/// are `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// `RecordingBackendResolver` is `nonisolated`; calling it from `@MainActor` is fine.
@Suite("RecordingBackendResolver — pure resolver outcomes")
@MainActor
struct RecordingBackendResolverTests {
    // MARK: - nil persisted → all stages live

    /// When `persisted` is `nil` (first launch or cleared), every stage resolves to `.live`.
    @Test("nil persisted → all stages resolve to .live")
    func nilPersisted_allStagesResolveLive() {
        let result = RecordingBackendResolver.resolve(
            persisted: nil,
            supported: .allSupported
        )
        #expect(result == ResolvedBackendSelection(source: .live, encoder: .live, writer: .live))
    }

    // MARK: - Unknown raw string → fallback to .live for that stage

    /// When one stage contains an unrecognised raw string, that stage falls back to `.live`
    /// while the other stages resolve to their persisted values (`.live` today).
    @Test("unknown source raw string → source resolves to .live, others to their persisted values")
    func unknownSourceRawString_sourceFallsBackToLive() {
        let persisted = PersistedBackendSelection(
            source: "bogus",
            encoder: "live",
            writer: "live"
        )
        let result = RecordingBackendResolver.resolve(
            persisted: persisted,
            supported: .allSupported
        )
        #expect(result.source == .live)
        #expect(result.encoder == .live)
        #expect(result.writer == .live)
    }

    // MARK: - Known but unsupported → fallback to .live for that stage

    /// When the persisted source backend is known (`.live`) but `isSourceLiveSupported` is
    /// `false`, the source stage falls back to `.live`; the other stages are unaffected.
    @Test("known source backend but not supported → source falls back to .live")
    func knownSourceNotSupported_sourceFallsBackToLive() {
        let persisted = PersistedBackendSelection(
            source: SourceBackend.live.rawString,
            encoder: EncoderBackend.live.rawString,
            writer: WriterBackend.live.rawString
        )
        let supported = SupportedBackends(
            isSourceLiveSupported: false,
            isEncoderLiveSupported: true,
            isWriterLiveSupported: true
        )
        let result = RecordingBackendResolver.resolve(persisted: persisted, supported: supported)
        #expect(result.source == .live)
        #expect(result.encoder == .live)
        #expect(result.writer == .live)
    }

    // MARK: - Known and supported → resolves to persisted value

    /// When every stage has a known raw string and all `SupportedBackends` flags are `true`,
    /// the resolver returns the persisted values for all stages.
    @Test("all known and supported → resolves to persisted values")
    func allKnownAndSupported_resolvesToPersistedValues() {
        let persisted = PersistedBackendSelection(
            source: SourceBackend.live.rawString,
            encoder: EncoderBackend.live.rawString,
            writer: WriterBackend.live.rawString
        )
        let result = RecordingBackendResolver.resolve(
            persisted: persisted,
            supported: .allSupported
        )
        #expect(result == ResolvedBackendSelection(source: .live, encoder: .live, writer: .live))
    }
}
