// swiftlint:disable file_length
// Rationale: this file is a set of small, documented, single-purpose policy value types
// (Container, VideoCodec, BitrateKey, SourceDimensions, DiskThresholds, DiskVerdict family,
// EngineBudgetCap) plus their `nonisolated` witnesses. Length grows with the policy surface,
// not with logic complexity — splitting it would scatter a tightly related contract.

// MARK: - Container

/// Output file container format.
///
/// Maps to AVFileType at the AVAssetWriter layer; the plain-Swift representation here
/// keeps `RecordingConfiguration` free of AVFoundation imports (purity seam).
enum Container {
    /// MPEG-4 container (.mp4). Required by AC-4.
    case mp4
}

extension Container: Equatable {
    /// Manual `nonisolated` implementation so `==` is usable from any isolation context.
    ///
    /// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, synthesised conformances are
    /// inferred as `@MainActor` (`InferIsolatedConformances`). All domain value-type enums
    /// in this project override this via manual nonisolated extensions — see `PermissionStatus`.
    nonisolated static func == (lhs: Container, rhs: Container) -> Bool {
        switch (lhs, rhs) {
        case (.mp4, .mp4):
            true
        }
    }
}

// MARK: - VideoCodec

/// Video codec family.
enum VideoCodec {
    /// High Efficiency Video Coding. Required by AC-4.
    case hevc
}

extension VideoCodec: Equatable {
    nonisolated static func == (lhs: VideoCodec, rhs: VideoCodec) -> Bool {
        switch (lhs, rhs) {
        case (.hevc, .hevc):
            true
        }
    }
}

// MARK: - HEVCSampleEntry

/// HEVC sample entry tag written to the MP4 container.
///
/// `hvc1` stores parameter sets in-band (no separate `hvcC` box at the start), which
/// gives better seek behaviour and is the required value per AC-4.
enum HEVCSampleEntry {
    case hvc1
}

extension HEVCSampleEntry: Equatable {
    nonisolated static func == (lhs: HEVCSampleEntry, rhs: HEVCSampleEntry) -> Bool {
        switch (lhs, rhs) {
        case (.hvc1, .hvc1):
            true
        }
    }
}

// MARK: - HEVCProfileLevel

/// HEVC profile / level hint.
///
/// This is a pure-Swift representation. The mapping to the VideoToolbox CFString constant
/// (e.g. `kVTProfileLevel_HEVC_Main_AutoLevel`) happens in the impure encoder layer, not
/// here. The exact constant name is marked as a Known Unknown in the spec (Open Questions)
/// and must be confirmed against the macOS 26.x VideoToolbox headers at encoder-setup time.
enum HEVCProfileLevel {
    /// HEVC Main profile, auto level — the encoder chooses the appropriate level.
    /// Required by the spec ("ProfileLevel = HEVC_Main_AutoLevel, 8-bit").
    case mainAutoLevel
}

extension HEVCProfileLevel: Equatable {
    nonisolated static func == (lhs: HEVCProfileLevel, rhs: HEVCProfileLevel) -> Bool {
        switch (lhs, rhs) {
        case (.mainAutoLevel, .mainAutoLevel):
            true
        }
    }
}

// MARK: - ColorPrimaries

/// Color primaries of the video signal.
///
/// Corresponds to ITU-T H.273 ColourPrimaries values. The encoder layer maps these to
/// the appropriate CMFormatDescription color space tags.
enum ColorPrimaries {
    /// ITU-R BT.709 primaries — standard SDR for HD/4K content. Required by AC-4.
    case rec709
}

extension ColorPrimaries: Equatable {
    nonisolated static func == (lhs: ColorPrimaries, rhs: ColorPrimaries) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - TransferFunction

/// Opto-electronic transfer function (gamma curve).
enum TransferFunction {
    /// ITU-R BT.709 transfer function — SDR. Required by AC-4.
    case rec709
}

extension TransferFunction: Equatable {
    nonisolated static func == (lhs: TransferFunction, rhs: TransferFunction) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - YCbCrMatrix

/// YCbCr colour matrix.
enum YCbCrMatrix {
    /// ITU-R BT.709 matrix. Required for SDR Rec.709 content.
    case rec709
}

extension YCbCrMatrix: Equatable {
    nonisolated static func == (lhs: YCbCrMatrix, rhs: YCbCrMatrix) -> Bool {
        switch (lhs, rhs) {
        case (.rec709, .rec709):
            true
        }
    }
}

// MARK: - PixelFormat

/// Pixel buffer format preference for the encoder input.
///
/// The spec requires zero-copy: IOSurface-backed CVPixelBuffers must be in an
/// encoder-compatible format. The `pixelFormatPreference` list is tried in order;
/// the first format the source can deliver is used, avoiding hidden per-frame
/// conversions (Technical Constraints section).
///
/// Maps to CVPixelFormatType constants in the encoder layer (no C-interop here):
/// - `.biPlanar420v` → kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  ("420v")
/// - `.biPlanar420f` → kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   ("420f")
enum PixelFormat {
    /// 4:2:0 bi-planar, video-range (Y [16,235], Cb/Cr [16,240]). Preferred.
    case biPlanar420v
    /// 4:2:0 bi-planar, full-range (Y/Cb/Cr [0,255]).
    case biPlanar420f
}

extension PixelFormat: Equatable {
    nonisolated static func == (lhs: PixelFormat, rhs: PixelFormat) -> Bool {
        switch (lhs, rhs) {
        case (.biPlanar420v, .biPlanar420v),
             (.biPlanar420f, .biPlanar420f):
            true

        default:
            false
        }
    }
}

// MARK: - BitrateKey

/// Lookup key into the VBR average-bitrate table.
///
/// Resolution is expressed as pixel count (width × height) + fps.
/// The encoder layer resolves a concrete pixel size to the nearest table entry.
nonisolated struct BitrateKey {
    /// Frame width in pixels.
    nonisolated let width: Int
    /// Frame height in pixels.
    nonisolated let height: Int
    /// Frames per second (integer; fractional fps not used in MVP).
    nonisolated let fps: Int

    nonisolated var pixelCount: Int {
        self.width * self.height
    }
}

// swiftformat:disable:next redundantEquatable
extension BitrateKey: Equatable {
    /// Explicit `nonisolated` operator — required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    /// The compiler infers synthesised `==` as `@MainActor`-isolated, making it unusable from
    /// `nonisolated` contexts (e.g. the bitrate-table lookup in `RecordingConfiguration`).
    nonisolated static func == (lhs: BitrateKey, rhs: BitrateKey) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.fps == rhs.fps
    }
}

// `BitrateKey` intentionally does NOT conform to `Hashable`.
// Under `InferIsolatedConformances` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, even
// manually-written `hash(into:)` extensions on a non-isolated struct cause the conformance
// itself to be inferred as `@MainActor`, which makes the conformance unusable from
// `nonisolated` contexts. The storage type in `RecordingConfiguration` is therefore
// `[(key: BitrateKey, value: Int)]` (a linear-scan array) instead of `[BitrateKey: Int]`.
// The bitrate table is small (O(10) entries), so linear lookup is negligible.

// MARK: - SourceDimensions

/// Width × height × fps for one capture source.
///
/// Used by `EngineBudgetCap.fits(screen:camera:)` to avoid a six-parameter function.
nonisolated struct SourceDimensions {
    /// Frame width in pixels.
    nonisolated let width: Int
    /// Frame height in pixels.
    nonisolated let height: Int
    /// Frames per second.
    nonisolated let fps: Int

    nonisolated var pixelRate: Int {
        self.width * self.height * self.fps
    }
}

// MARK: - DiskThresholds

/// Thresholds and cadence for proactive disk-space monitoring during recording (spec #88).
///
/// Pure data, no framework dependency; values live on `RecordingConfiguration.mvpDefault` — no
/// threshold literal is hardcoded elsewhere in the pipeline. Byte thresholds are the PRIMARY
/// stop signal (fire regardless of estimated time-to-full, incl. slope ≤ 0); ETA thresholds are
/// SECONDARY, gated on `slopeConfidence` (`...ImportantUsage` includes purgeable space whose
/// recompute swings can dwarf the true write-speed slope near a full volume).
///
/// `ewmaTimeConstantSeconds` MUST be ≥ 4× `RecordingConfiguration.movieFragmentInterval` — at
/// `readEverySeconds` ≈ `movieFragmentInterval` the EWMA window then reflects ≥ 4 reads, enough
/// to damp a flush burst without smoothing away a real sustained drain.
nonisolated struct DiskThresholds: Equatable {
    /// System volume free-bytes warning floor → `.warning(.systemFree)` (recording continues).
    nonisolated let systemWarnBytes: Int64
    /// System volume free-bytes critical floor → `.critical(.systemFree)` (auto-stop).
    nonisolated let systemStopBytes: Int64
    /// Output volume free-bytes warning floor → `.warning(.outputFree)`.
    nonisolated let outputWarnBytes: Int64
    /// Output volume free-bytes critical floor → `.critical(.outputFree)` — the PRIMARY stop signal.
    nonisolated let outputStopBytes: Int64
    /// Output volume warning ETA threshold in seconds. Secondary, gated on `slopeConfidence`.
    nonisolated let outputWarnEtaSeconds: Double
    /// Output volume critical ETA threshold in seconds. Secondary, gated on `slopeConfidence`.
    nonisolated let outputStopEtaSeconds: Double
    /// EWMA time-constant (seconds) smoothing `−Δ(free bytes)/Δt`. MUST be
    /// ≥ 4× `RecordingConfiguration.movieFragmentInterval` — see type-level doc.
    nonisolated let ewmaTimeConstantSeconds: Double
    /// Cadence (seconds) `DiskSpaceMonitor` throttles the provider read to, independent of the
    /// ~1 Hz tick driving it. Approximately `RecordingConfiguration.movieFragmentInterval`.
    nonisolated let readEverySeconds: Double
    /// Duration (seconds) after monitoring starts during which the estimator falls back to the
    /// table bitrate sum instead of the not-yet-trusted EWMA slope.
    nonisolated let warmupSeconds: Double
    /// Byte margin a free-byte metric must recover past its warn threshold before a `.warning`
    /// is eligible to clear (hysteresis — AC-11).
    nonisolated let hysteresisReleaseBytes: Int64
    /// Minimum duration (seconds) recovered past the release margin before clearing (AC-11).
    nonisolated let deescalationDebounceSeconds: Double
}

// MARK: - DiskWarningReason

/// Reason a `.warning` disk verdict was raised (AC-3: the warning must be actionable).
enum DiskWarningReason {
    /// Output volume's estimated time-to-full crossed the warn ETA threshold.
    case outputEta
    /// Output volume's free bytes crossed the warn byte threshold.
    case outputFree
    /// System volume's free bytes crossed the warn byte threshold.
    case systemFree
}

extension DiskWarningReason: Equatable {
    /// Explicit `nonisolated` operator — `InferIsolatedConformances` would otherwise infer a
    /// `@MainActor`-isolated synthesized `==` even on this `nonisolated` enum.
    nonisolated static func == (lhs: DiskWarningReason, rhs: DiskWarningReason) -> Bool {
        switch (lhs, rhs) {
        case (.outputEta, .outputEta), (.outputFree, .outputFree), (.systemFree, .systemFree):
            true

        default:
            false
        }
    }
}

// MARK: - DiskStopReason

/// Reason a `.critical` disk verdict was raised (drives the auto-stop cause surfaced by AC-9).
enum DiskStopReason {
    /// Output volume's estimated time-to-full crossed the critical ETA threshold.
    case outputEta
    /// Output volume's free bytes crossed the critical byte threshold (byte-floor, primary signal).
    case outputFree
    /// System volume's free bytes crossed the critical byte threshold.
    case systemFree
}

extension DiskStopReason: Equatable {
    /// Explicit `nonisolated` operator — see `DiskWarningReason.==` rationale.
    nonisolated static func == (lhs: DiskStopReason, rhs: DiskStopReason) -> Bool {
        switch (lhs, rhs) {
        case (.outputEta, .outputEta), (.outputFree, .outputFree), (.systemFree, .systemFree):
            true

        default:
            false
        }
    }
}

// MARK: - DiskVerdict

/// The disk-space monitoring verdict for the current tick (AC-2/AC-3/AC-4).
enum DiskVerdict {
    // swiftlint:disable discouraged_none_name
    /// No disk-space concern; recording proceeds normally. Spec-defined case name (#88); never
    /// optional-typed, so no confusion with `Optional<T>.none`.
    case none
    // swiftlint:enable discouraged_none_name
    /// An actionable, non-blocking warning; recording continues (AC-3).
    case warning(DiskWarningReason)
    /// A critical condition; the coordinator MUST auto-stop recording gracefully (AC-4).
    case critical(DiskStopReason)
}

extension DiskVerdict: Equatable {
    /// Explicit `nonisolated` operator — required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    /// The #1 gotcha for this feature: both payload enums (`DiskWarningReason`/`DiskStopReason`)
    /// need the same treatment, or this witness fails to compile for `nonisolated` call sites.
    nonisolated static func == (lhs: DiskVerdict, rhs: DiskVerdict) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true

        case let (.warning(lhsReason), .warning(rhsReason)):
            lhsReason == rhsReason

        case let (.critical(lhsReason), .critical(rhsReason)):
            lhsReason == rhsReason

        default:
            false
        }
    }
}

// MARK: - ETAEstimate

/// A time-to-full estimate for a volume: produced by `DiskSpaceEstimator` for the idle
/// pre-flight headline (AC-1) and the ETA-gated in-recording verdict path.
nonisolated struct ETAEstimate: Equatable {
    /// Estimated seconds remaining until the volume is full, or `nil` when unavailable (bad
    /// data, no free-space reading, or zero/negative estimated speed with no byte-floor signal).
    nonisolated let secondsRemaining: Double?
    /// Whether `secondsRemaining` reflects a usable estimate. `false` means the caller should
    /// display "оценка недоступна" rather than a fabricated number.
    nonisolated let isEstimateAvailable: Bool
    /// SNR-proxy confidence in the estimated slope: `|ewmaSpeed| / max(ε, stddev(recentΔ))`.
    /// Below the calibrated cutoff, ETA-derived thresholds are suppressed and the byte-floor
    /// becomes the sole critical signal (see `DiskThresholds` type-level doc).
    nonisolated let slopeConfidence: Double
}

// MARK: - EngineBudgetCap

/// The throughput ceiling applied as a preflight cap before a recording session starts.
///
/// Coupled-quality (AC-Q9) supersedes the original single-value AC-5 placeholder: the cap is
/// no longer one static number for every chip, but produced per-`ChipTier` by
/// `budgetCap(for:codec:)` below. `mvpDefault` still carries the flat 995M px/s value (spec
/// anchor "один движок ≈ 4K120 ≈ ~995M px/s") only for non-budget-aware consumers that
/// construct `RecordingConfiguration` without a chip tier — see `makeMVPDefault`'s doc-comment.
/// The cap is applied by `CapabilityProbe`/`fits(screen:camera:)` before starting the session;
/// it is NOT a runtime throttle (post-MVP).
nonisolated struct EngineBudgetCap: Equatable {
    /// Maximum pixel-rate (pixels/second) the encode engine supports.
    ///
    /// Populated either from the flat 995_000_000 MVP default (non-budget-aware construction
    /// path, see type-level doc) or from `budgetCap(for:codec:)`'s per-tier value (622_080_000
    /// validated floor for `.m3Max` pending AC-Q4 calibration by T-6, 248_832_000 safe-low for
    /// `.uncalibrated`).
    nonisolated let maxPixelsPerSecond: Int

    /// Returns `true` when the given screen+camera combined pixel-rate fits within this cap.
    ///
    /// - Parameters:
    ///   - screen: Screen capture dimensions (width × height × fps).
    ///   - camera: Camera capture dimensions (width × height × fps).
    nonisolated func fits(screen: SourceDimensions, camera: SourceDimensions) -> Bool {
        screen.pixelRate + camera.pixelRate <= self.maxPixelsPerSecond
    }
}

// swiftlint:disable no_magic_numbers
// Rationale: same as `RecordingConfiguration`'s file-wide disable — these are documented,
// spec-anchored calibration values (validated floor / safe-low), not arbitrary literals.
extension EngineBudgetCap {
    /// Returns the per-chip-tier throughput ceiling (AC-Q9 device-budget coupling).
    ///
    /// Exhaustive `switch` over `ChipTier` — deliberately NOT a `[ChipTier: EngineBudgetCap]`
    /// dictionary, so a future `ChipTier` case fails to compile here until handled (the switch
    /// is the true completeness guard, not `CaseIterable`).
    ///
    /// - Parameters:
    ///   - tier: The AC-Q4 calibration tier of the host chip.
    ///   - codec: Reserved for a future per-codec throughput correction. Media-engine pixel-rate
    ///     throughput is codec-agnostic today (HEVC-only; AV1 is not HW-accelerated on Apple
    ///     Silicon ≤ M3), so this parameter is currently unused — Swift does not warn on unused
    ///     parameters.
    nonisolated static func budgetCap(for tier: ChipTier, codec: VideoCodec) -> EngineBudgetCap {
        switch tier {
        case .m3Max:
            // UNCALIBRATED floor (non-worst-case #281 seed), NOT AC-Q4 — Phase B MUST NOT wire
            // until T-6 sets the calibrated ceiling
            EngineBudgetCap(maxPixelsPerSecond: 622_080_000)

        case .uncalibrated:
            // safe-low, uncalibrated — never inherits the m3Max floor (AC-Q9)
            EngineBudgetCap(maxPixelsPerSecond: 248_832_000)
        }
    }
}

// swiftlint:enable no_magic_numbers
