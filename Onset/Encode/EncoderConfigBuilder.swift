// EncoderConfigBuilder.swift
// Onset
//
// Pure config-contract layer for the VideoEncoder (U1 of #31).
//
// PURITY SEAM: this file has NO VideoToolbox / CoreMedia / AVFoundation imports.
// The mapping from these plain-Swift values to VT CFString/CFNumber constants
// is performed in the impure encoder actor (U3). The design matches the
// `RecordingConfiguration` purity contract described in that type's header.
//
// Isolation: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `NonisolatedNonsendingByDefault`
// require explicit `nonisolated` on every member and a manual `nonisolated static func ==`
// — the compiler infers synthesised conformances as `@MainActor` (InferIsolatedConformances).
// Pattern mirrors `RecordingConfiguration` and its sibling types.

import Foundation

// MARK: - VTEncoderSettings

/// A flat, pure-Swift snapshot of all encoder parameters derived from `RecordingConfiguration`
/// and the resolved capture dimensions.
///
/// All values are plain Swift scalars or project-local enums — no VideoToolbox or CoreMedia
/// types appear here. The mapping to VT CFString / CFNumber constants lives in the encoder
/// actor (U3), keeping this type usable from any isolation context without framework imports.
///
/// The `nonisolated` annotation on every stored property and on the manual `==` witness is
/// required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so the struct is usable from
/// `nonisolated` contexts (e.g. `EncoderConfigBuilder.build`, actor init, unit tests).
nonisolated struct VTEncoderSettings: Equatable {
    // MARK: - Rate control

    /// Average encoder bitrate in bits per second.
    ///
    /// Resolved via `RecordingConfiguration.averageBitrate(forWidth:height:fps:)`.
    nonisolated let averageBitRate: Int

    /// Peak bitrate cap in bits per second (DataRateLimits[1]).
    ///
    /// = `averageBitRate × RecordingConfiguration.dataRateLimitsPeakMultiplier`, rounded.
    /// Encoders that do not support DataRateLimits must fall back to AverageBitRate-only
    /// and log the event; that fallback lives in the encoder actor (U3), not here.
    nonisolated let peakDataRate: Int

    // MARK: - GOP

    /// Maximum key-frame interval in seconds (`MaxKeyFrameIntervalDuration`).
    ///
    /// Mapped from `RecordingConfiguration.keyFrameIntervalSeconds`.
    nonisolated let maxKeyFrameIntervalDurationSeconds: Double

    // MARK: - Profile

    /// HEVC profile / level hint.
    ///
    /// The mapping to the VideoToolbox CFString constant (e.g.
    /// `kVTProfileLevel_HEVC_Main_AutoLevel`) happens in the encoder layer (U3).
    nonisolated let profileLevel: HEVCProfileLevel

    // MARK: - Frame reordering / timing

    /// Whether B-frames are permitted (`AllowFrameReordering`).
    nonisolated let allowFrameReordering: Bool

    /// Whether the encoder should optimise for real-time capture (`RealTime`).
    ///
    /// Always `true` for screen/camera recording — there is no config field for this
    /// because the recording use-case mandates real-time mode unconditionally.
    nonisolated let realTime: Bool

    // MARK: - Bit depth

    /// Luma bit depth. Spec: "8-bit" (HEVC Main profile). Mapped from `RecordingConfiguration.bitDepth`.
    nonisolated let bitDepth: Int

    // MARK: - Color metadata (Rec.709 SDR)

    /// Color primaries of the video signal.
    nonisolated let colorPrimaries: ColorPrimaries

    /// Opto-electronic transfer function.
    nonisolated let transferFunction: TransferFunction

    /// YCbCr colour matrix.
    nonisolated let yCbCrMatrix: YCbCrMatrix

    // MARK: - Init

    /// Creates a validated encoder-settings snapshot.
    ///
    /// Defined in the struct body (not an extension) so it SUPPRESSES the synthesised
    /// memberwise initializer — there must be no precondition-free backdoor to a semantically
    /// invalid VT config (F5). `EncoderConfigBuilder.build` is the normal construction path,
    /// but direct construction must also hold these numeric invariants:
    /// - `averageBitRate > 0` — VT rejects a non-positive target bitrate.
    /// - `peakDataRate >= averageBitRate` — the peak cap must not sit below the average.
    /// - `maxKeyFrameIntervalDurationSeconds > 0` — a non-positive GOP duration is meaningless.
    ///
    /// `nonisolated` is required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so the type
    /// stays constructible from any isolation context.
    nonisolated init(
        averageBitRate: Int,
        peakDataRate: Int,
        maxKeyFrameIntervalDurationSeconds: Double,
        profileLevel: HEVCProfileLevel,
        allowFrameReordering: Bool,
        realTime: Bool,
        bitDepth: Int,
        colorPrimaries: ColorPrimaries,
        transferFunction: TransferFunction,
        yCbCrMatrix: YCbCrMatrix
    ) {
        precondition(averageBitRate > 0, "averageBitRate must be positive")
        precondition(peakDataRate >= averageBitRate, "peakDataRate must be >= averageBitRate")
        precondition(
            maxKeyFrameIntervalDurationSeconds > 0,
            "maxKeyFrameIntervalDurationSeconds must be positive"
        )

        self.averageBitRate = averageBitRate
        self.peakDataRate = peakDataRate
        self.maxKeyFrameIntervalDurationSeconds = maxKeyFrameIntervalDurationSeconds
        self.profileLevel = profileLevel
        self.allowFrameReordering = allowFrameReordering
        self.realTime = realTime
        self.bitDepth = bitDepth
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }
}

// MARK: - Equatable

extension VTEncoderSettings {
    /// Manual `nonisolated` witness — required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    ///
    /// The conformance is declared on the primary `nonisolated struct` definition (not here in
    /// the extension) so the witness table entry inherits nonisolated isolation. A conformance
    /// declared in a bare `extension VTEncoderSettings: Equatable` block would be inferred as
    /// `@MainActor` under `InferIsolatedConformances`, breaking use from nonisolated contexts
    /// such as the `#expect` macro expansion in Swift Testing. Pattern mirrors `EngineBudgetCap`.
    nonisolated static func == (lhs: VTEncoderSettings, rhs: VTEncoderSettings) -> Bool {
        lhs.averageBitRate == rhs.averageBitRate
            && lhs.peakDataRate == rhs.peakDataRate
            && lhs.maxKeyFrameIntervalDurationSeconds == rhs.maxKeyFrameIntervalDurationSeconds
            && lhs.profileLevel == rhs.profileLevel
            && lhs.allowFrameReordering == rhs.allowFrameReordering
            && lhs.realTime == rhs.realTime
            && lhs.bitDepth == rhs.bitDepth
            && lhs.colorPrimaries == rhs.colorPrimaries
            && lhs.transferFunction == rhs.transferFunction
            && lhs.yCbCrMatrix == rhs.yCbCrMatrix
    }
}

// MARK: - EncoderConfigBuilder

/// Pure mapping from `RecordingConfiguration` + resolved capture dimensions to `VTEncoderSettings`.
///
/// This is a stateless, synchronous transform — no actor isolation, no async, no I/O.
/// The builder is intentionally not a type instance: a free `nonisolated static func` is
/// the simplest callable surface and avoids synthesised `@MainActor` conformances on an
/// otherwise inert namespace type.
nonisolated enum EncoderConfigBuilder {
    /// Builds a `VTEncoderSettings` value from the given recording configuration and capture dimensions.
    ///
    /// - Parameters:
    ///   - config: The canonical recording policy (use `RecordingConfiguration.mvpDefault` in production).
    ///   - width: Capture frame width in pixels (resolved at runtime from the active source).
    ///   - height: Capture frame height in pixels.
    ///   - fps: Capture frame rate in frames per second (integer; fractional fps not used in MVP).
    /// - Returns: A fully populated `VTEncoderSettings` ready for the encoder actor.
    nonisolated static func build(
        config: RecordingConfiguration,
        width: Int,
        height: Int,
        fps: Int
    ) -> VTEncoderSettings {
        let averageBitRate = config.averageBitrate(forWidth: width, height: height, fps: fps)

        // Peak = average × multiplier, rounded to the nearest integer.
        // With multiplier 2.0 every MVP table entry produces an exact integer;
        // `.rounded()` keeps the expression correct for future calibrated values.
        let peakDataRate = Int((Double(averageBitRate) * config.dataRateLimitsPeakMultiplier).rounded())

        return VTEncoderSettings(
            averageBitRate: averageBitRate,
            peakDataRate: peakDataRate,
            maxKeyFrameIntervalDurationSeconds: config.keyFrameIntervalSeconds,
            profileLevel: config.profileLevel,
            allowFrameReordering: config.allowFrameReordering,
            // `realTime = true` is unconditional for recording — no config field controls this.
            // Recording is always a live, real-time capture; the distinction only matters for
            // offline transcoding, which is out of scope.
            realTime: true,
            bitDepth: config.bitDepth,
            colorPrimaries: config.colorPrimaries,
            transferFunction: config.transferFunction,
            yCbCrMatrix: config.yCbCrMatrix
        )
    }
}
