// MARK: - SourceBackend

/// Recording backend used for the capture (source) stage of the pipeline.
///
/// Single-case today (`.live`); additional cases — e.g. a replay or mock backend —
/// can be added without changing the persistence contract, because serialisation uses
/// `rawString`, not the Swift identifier.
enum SourceBackend {
    /// The live AVFoundation / ScreenCaptureKit capture backend.
    case live
}

extension SourceBackend: Equatable {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Under `InferIsolatedConformances`, synthesised `==` is inferred as `@MainActor`-isolated,
    /// making it unusable from `nonisolated` contexts (e.g. `RecordingBackendResolver`).
    nonisolated static func == (lhs: SourceBackend, rhs: SourceBackend) -> Bool {
        switch (lhs, rhs) {
        case (.live, .live):
            true
        }
    }
}

extension SourceBackend {
    /// The canonical string used for persistence and round-trip (de)serialisation.
    ///
    /// Independent of the Swift case identifier — renaming `.live` in Swift does not silently
    /// break stored values. The resolver compares this string, not the case name.
    nonisolated var rawString: String {
        switch self {
        case .live:
            "live"
        }
    }

    /// Creates a `SourceBackend` from a canonical raw string, or returns `nil` for unrecognised values.
    ///
    /// - Parameter rawString: A value previously produced by `rawString`.
    nonisolated init?(rawString: String) {
        switch rawString {
        case "live":
            self = .live

        default:
            return nil
        }
    }
}

// MARK: - EncoderBackend

/// Recording backend used for the encode stage of the pipeline.
///
/// Single-case today (`.live`); additional cases can be added without breaking
/// persistence because serialisation is anchored to `rawString`.
enum EncoderBackend {
    /// The live VideoToolbox HEVC hardware encoder backend.
    case live
}

extension EncoderBackend: Equatable {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Under `InferIsolatedConformances`, synthesised `==` is inferred as `@MainActor`-isolated,
    /// making it unusable from `nonisolated` contexts (e.g. `RecordingBackendResolver`).
    nonisolated static func == (lhs: EncoderBackend, rhs: EncoderBackend) -> Bool {
        switch (lhs, rhs) {
        case (.live, .live):
            true
        }
    }
}

extension EncoderBackend {
    /// The canonical string used for persistence and round-trip (de)serialisation.
    ///
    /// Independent of the Swift case identifier — renaming `.live` in Swift does not silently
    /// break stored values. The resolver compares this string, not the case name.
    nonisolated var rawString: String {
        switch self {
        case .live:
            "live"
        }
    }

    /// Creates an `EncoderBackend` from a canonical raw string, or returns `nil` for unrecognised values.
    ///
    /// - Parameter rawString: A value previously produced by `rawString`.
    nonisolated init?(rawString: String) {
        switch rawString {
        case "live":
            self = .live

        default:
            return nil
        }
    }
}

// MARK: - WriterBackend

/// Recording backend used for the writer (muxing + file output) stage of the pipeline.
///
/// Single-case today (`.live`); additional cases can be added without breaking
/// persistence because serialisation is anchored to `rawString`.
enum WriterBackend {
    /// The live AVAssetWriter MP4 muxing backend.
    case live
}

extension WriterBackend: Equatable {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Under `InferIsolatedConformances`, synthesised `==` is inferred as `@MainActor`-isolated,
    /// making it unusable from `nonisolated` contexts (e.g. `RecordingBackendResolver`).
    nonisolated static func == (lhs: WriterBackend, rhs: WriterBackend) -> Bool {
        switch (lhs, rhs) {
        case (.live, .live):
            true
        }
    }
}

extension WriterBackend {
    /// The canonical string used for persistence and round-trip (de)serialisation.
    ///
    /// Independent of the Swift case identifier — renaming `.live` in Swift does not silently
    /// break stored values. The resolver compares this string, not the case name.
    nonisolated var rawString: String {
        switch self {
        case .live:
            "live"
        }
    }

    /// Creates a `WriterBackend` from a canonical raw string, or returns `nil` for unrecognised values.
    ///
    /// - Parameter rawString: A value previously produced by `rawString`.
    nonisolated init?(rawString: String) {
        switch rawString {
        case "live":
            self = .live

        default:
            return nil
        }
    }
}

// MARK: - ResolvedBackendSelection

/// The resolved backend selection for a single recording session.
///
/// Produced by `RecordingBackendResolver` after applying fallback logic; all fields
/// are guaranteed to be supported values. Consumed by the composition root to construct
/// the concrete pipeline stages.
///
/// Declared `nonisolated` so that `RecordingBackendResolver` — a `nonisolated enum` — can
/// construct and return this type without a `MainActor` hop, matching the pattern of
/// `RecordingConfiguration` and `BitrateKey` in this project.
nonisolated struct ResolvedBackendSelection {
    /// The resolved capture backend for the source stage.
    nonisolated let source: SourceBackend
    /// The resolved backend for the encode stage.
    nonisolated let encoder: EncoderBackend
    /// The resolved backend for the writer (muxing + file output) stage.
    nonisolated let writer: WriterBackend
}

// swiftformat:disable:next redundantEquatable
extension ResolvedBackendSelection: Equatable {
    /// Manual `nonisolated` operator required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// Mirrors `BitrateKey`: on a `nonisolated struct`, the compiler still infers the
    /// synthesised `==` as `@MainActor`-isolated under `InferIsolatedConformances`,
    /// so an explicit `nonisolated` witness is needed.
    nonisolated static func == (lhs: ResolvedBackendSelection, rhs: ResolvedBackendSelection) -> Bool {
        lhs.source == rhs.source && lhs.encoder == rhs.encoder && lhs.writer == rhs.writer
    }
}

// MARK: - PersistedBackendSelection

/// The raw persisted form of a backend selection stored in `UserDefaults`.
///
/// Each field is an optional `String` holding the `rawString` of the corresponding
/// backend enum. `nil` means "not set" — the resolver applies the default (`.live`)
/// for any absent or unrecognised field.
///
/// Field names are the Codable keys and are fixed; do not rename them.
struct PersistedBackendSelection: Codable, Equatable {
    /// The persisted raw string for `SourceBackend`, or `nil` if not set.
    var source: String?
    /// The persisted raw string for `EncoderBackend`, or `nil` if not set.
    var encoder: String?
    /// The persisted raw string for `WriterBackend`, or `nil` if not set.
    var writer: String?
}
