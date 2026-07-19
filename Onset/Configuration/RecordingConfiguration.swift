import Foundation

// swiftlint:disable file_length
// Rationale: this is a single flat policy value type — its length is the sum of one documented
// `nonisolated let` per recording-policy knob plus the manual `nonisolated ==` witness. Splitting
// it across files would scatter the contract; the count grows with the policy surface, not with logic.

// swiftlint:disable no_magic_numbers
// Rationale: the numeric literals in this file are calibration-placeholder values for
// VBR bitrate targets and the engine-throughput budget cap. They are not "magic" — each
// is documented with its source (spec anchor or research report) and is expected to be
// tuned post-MVP against real hardware. Disabling the rule file-wide avoids cluttering
// every constant with a named-constant indirection layer that provides no semantic value
// before calibration.

// MARK: - RecordingConfiguration

/// Pure recording policy: codec settings, rate control, pixel preferences, and file layout.
///
/// This type holds POLICY only — plain Swift values, no VideoToolbox/CoreMedia/CoreVideo
/// imports. The mapping from these values to framework constants happens in the encoder
/// and writer layers.
///
/// ### Numeric values are calibration placeholders
/// VBR bitrate targets (`bitrateTable`, `dataRateLimitsPeakMultiplier`) are starting
/// hypotheses based on industry knowledge. They MUST be calibrated against real Apple
/// Silicon hardware (M1 Air through M3 Max) before the MVP ships. The structure is the
/// contract; the scalars are not.
///
/// ### DataRateLimits fallback
/// The encoder layer must handle `kVTPropertyNotSupportedErr` returned by some hardware
/// encoders when setting DataRateLimits (peak cap). In that case, fall back to
/// AverageBitRate-only and log the event via `os.Logger`. This fallback is implemented
/// in the encoder, not here.
///
/// All members are `nonisolated` so this pure value type is usable from any isolation
/// context without actor hopping (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated struct RecordingConfiguration {
    // MARK: - Container & Codec

    /// Output file container. AC-4: must be `.mp4`.
    nonisolated let container: Container
    /// Video codec. AC-4: must be `.hevc`.
    nonisolated let codec: VideoCodec
    /// HEVC sample entry tag in the MP4 container. AC-4: must be `.hvc1`.
    nonisolated let sampleEntry: HEVCSampleEntry
    /// HEVC profile / level. Spec: "ProfileLevel = HEVC_Main_AutoLevel".
    nonisolated let profileLevel: HEVCProfileLevel

    // MARK: - Color

    /// Color primaries. Spec: "SDR Rec.709".
    nonisolated let colorPrimaries: ColorPrimaries
    /// Transfer function. Spec: "SDR Rec.709".
    nonisolated let transferFunction: TransferFunction
    /// YCbCr matrix. Spec: "SDR Rec.709".
    nonisolated let yCbCrMatrix: YCbCrMatrix
    /// Bit depth. Spec: "8-bit". AC-4.
    nonisolated let bitDepth: Int

    // MARK: - Frame Rate

    /// Maximum screen recording frame rate (fps). AC-5: target fps = min(native refresh, 60).
    nonisolated let maxScreenFps: Int
    /// Minimum camera recording frame rate (fps). AC-5: camera auto-selects highest
    /// resolution format with fps ≥ this value.
    nonisolated let minCameraFps: Int

    // MARK: - Camera

    /// Whether the camera image is horizontally mirrored in the recorded output.
    ///
    /// Capture-side preference (consistent with `minCameraFps`), read fresh at record start and
    /// applied to the recording VDO connection's `isVideoMirrored` at session setup. The live
    /// preview honors the same value reactively; the recorded file honors it from the next
    /// session start. Default `false` (raw sensor orientation).
    nonisolated let cameraMirror: Bool

    // MARK: - Rate Control (VBR)

    /// Average-bitrate lookup table as an ordered array of (key, value) pairs.
    ///
    /// VBR rate control: the encoder layer sets `AverageBitRate` from this table and
    /// `DataRateLimits` = average × `dataRateLimitsPeakMultiplier` as the peak cap.
    ///
    /// Array (not `Dictionary`) because `BitrateKey: Hashable` cannot be made `nonisolated`
    /// under `InferIsolatedConformances` — see `BitrateKey` comment above. Linear scan is
    /// acceptable for a table of O(10) entries.
    ///
    /// **Values are placeholders** — calibrate before MVP ship. See type-level doc.
    nonisolated let bitrateTable: [(key: BitrateKey, value: Int)]

    /// Peak-bitrate multiplier applied on top of the average bitrate.
    ///
    /// DataRateLimits peak = averageBitrate × this multiplier. Typical range 1.5–2.5.
    /// **Placeholder** — calibrate post-MVP.
    nonisolated let dataRateLimitsPeakMultiplier: Double

    // MARK: - GOP / Reordering

    /// Key-frame interval in seconds. Used to compute `MaxKeyFrameInterval` for the
    /// encoder. A stable GOP simplifies CFR and seek. **Placeholder**.
    nonisolated let keyFrameIntervalSeconds: Double

    /// Whether B-frames are permitted (`AllowFrameReordering`).
    ///
    /// Set to `false` for real-time capture: the HEVC encoder's reorder window holds
    /// `NumberOfPendingFrames` at a floor of ~4 — at or above the `VideoEncoder`
    /// backpressure gate threshold (`maxPendingFrames = 4`) — so a healthy pipeline
    /// structurally gate-drops CFR slots (camera ~17% loss, screen ~40%; issue #112).
    /// DTS == PTS and minimal encoder latency are also desirable for capture.
    /// The compression benefit of B-frames is not worth a broken cadence.
    nonisolated let allowFrameReordering: Bool

    // MARK: - Pixel Format Preference

    /// Ordered list of preferred pixel formats for encoder input, most-preferred first.
    ///
    /// The capture layer tries formats in this order and uses the first one the source
    /// can deliver without a CPU-copy conversion. See `PixelFormat` doc.
    nonisolated let pixelFormatPreference: [PixelFormat]

    // MARK: - Audio (MVP: mono microphone input)

    /// Microphone sample rate in Hz. AAC encoder target.
    ///
    /// 48 kHz is the standard broadcast/recording sample rate and is natively supported
    /// by every macOS audio device. Placeholder — calibrate post-MVP.
    nonisolated let audioSampleRate: Double

    /// Microphone channel count. 1 = mono mic MVP.
    ///
    /// Single-channel matches the single-microphone MVP scope. Post-MVP: per-file mic
    /// selection may require stereo (2 channels). Placeholder — calibrate post-MVP.
    nonisolated let audioChannelCount: Int

    /// AAC target bitrate in bits per second.
    ///
    /// 128 kbps is a common high-quality mono AAC target. Placeholder — calibrate post-MVP.
    nonisolated let audioBitrate: Int

    // MARK: - File Durability

    /// Movie-fragment interval in seconds.
    ///
    /// `AVAssetWriter.movieFragmentInterval` controls how often the container is
    /// finalised in-stream. Shorter = less data lost on crash. Spec: "рекомендуется 2–5 с";
    /// AC-10: file must be valid after a crash. Set to 4 s.
    nonisolated let movieFragmentInterval: Double

    // MARK: - Degraded-State Policy (DropMonitor #35)

    /// Backpressure-drop count within `degradedWindowSeconds` above which the session is
    /// reported `.degraded`. Strict comparison: `count > threshold` → degraded.
    ///
    /// Only `DropReason.encoderBackpressureDrops` feed this window (capture / CFR drops do not).
    /// **Placeholder** — calibrate post-MVP against real hardware drop rates.
    nonisolated let degradedBackpressureThreshold: Int

    /// Sliding-window length (seconds) over which backpressure drops are counted for the
    /// degraded-state decision. Drops older than `now − degradedWindowSeconds` are evicted,
    /// so when backpressure stops the window empties and the session recovers to `.normal`.
    /// **Placeholder** — calibrate post-MVP.
    nonisolated let degradedWindowSeconds: Double

    /// Minimum cumulative encoder-backpressure drop count across the whole session that triggers
    /// the post-stop "возможны рывки" alert (AC-9). Inclusive: `total >= threshold` → alert.
    ///
    /// Intentionally separate from `degradedBackpressureThreshold` (the live sliding-window rate
    /// threshold, AC-8): the live indicator measures rate within a short window; the post-stop
    /// alert measures the session-total and should only fire for a significant number of drops.
    /// `>= threshold` here vs `>` in AC-8 — each comparison matches its own spec wording.
    /// **Placeholder** — calibrate post-MVP against real hardware drop rates.
    nonisolated let postStopDropWarningThreshold: Int

    // MARK: - Critical Recording Signals

    /// Continuous duration (seconds) the session must stay `.degraded` before it escalates to a
    /// live `hard` `sustainedDrops` incident. A transient (< this) stays yellow / disk-only.
    /// Spec §2 "Live"; AC-3(a).
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let criticalSustainSeconds = 10.0

    /// Post-stop normalized drop intensity (drops/min) at or above which a session is reported as a
    /// `hard` post-stop incident, gated by `criticalDropRateMinSessionSeconds`. Spec §2 "Пост-стоп"; AC-4.
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let criticalDropRatePerMin = 600

    /// Session-duration floor (seconds) below which the post-stop drop-rate criterion does NOT apply.
    /// Guards against a short clip (e.g. a 2 s capture with a high count) producing a false rate. Spec §2; AC-4.
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let criticalDropRateMinSessionSeconds = 10.0

    /// Fraction of the measured baseline below which delivered fps becomes a collapse candidate
    /// (`delivered < ratio × baseline`). Spec §3 "срабатывание".
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let fpsCollapseRatio = 0.5

    /// Continuous duration (seconds) the dip must hold below `fpsCollapseRatio × baseline` to fire a
    /// collapse, given a corroborating drop/gap signal. Spec §3 "срабатывание"; AC-5.
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let fpsCollapseWindowSeconds = 5.0

    /// `gap_ms_max` threshold (milliseconds) above which a frame gap corroborates a collapse candidate
    /// (alternative to a nonzero drop/overflow rate). Spec §3 "срабатывание".
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let fpsCollapseGapMsThreshold = 250

    /// Window (seconds) over which the adaptive camera-fps baseline is averaged. Chosen `>>`
    /// `fpsCollapseWindowSeconds` so a short collapse barely moves the baseline. Spec §3 "baseline".
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let cameraBaselineWindowSeconds = 30.0

    /// Cold-start ramp (seconds) discarded from the start of capture before samples feed the baseline,
    /// so the warm-up ramp does not depress the average. Spec §3 "baseline".
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let cameraBaselineSkipSeconds = 2.0

    /// Dedupe window (seconds) for live critical notifications: the first notification in the window
    /// suppresses later same-or-lower-tier ones (higher tier always breaks through). Spec "Дедуп".
    /// calibrate post-MVP via L5 (MX Brio); future: expose in Settings
    nonisolated let criticalNotificationDedupeSeconds = 10.0

    // MARK: - Engine Budget Cap

    /// Throughput ceiling for the encode engine. Used by CapabilityProbe pre-flight.
    ///
    /// Spec anchor: "один движок ≈ 4K120 ≈ ~995M px/s" (CapabilityProbe section).
    /// AC-5: screen resolution is capped so combined pixel-rate stays within this budget.
    nonisolated let budgetCap: EngineBudgetCap

    // MARK: - Disk Space Monitoring (#88)

    /// Thresholds and cadence for proactive disk-space monitoring during recording.
    ///
    /// **Placeholders** — reasoned defaults pending L5 calibration (AC-10). See `DiskThresholds`.
    nonisolated let diskThresholds: DiskThresholds

    // MARK: - Output Directory

    /// Base directory under which session subdirectories are created (`~/Movies/Onset/` by default).
    ///
    /// A session-scoped subdirectory (`"Onset YYYY-MM-DD HH.mm.ss"`) is created inside this
    /// directory at recording start. This property provides the target base URL; the subdirectory
    /// and its files are created lazily by `RecordingOutput.ensureDirectory(_:)`.
    /// Spec: `~/Movies/Onset/`; Technical Constraints: Developer ID path, no sandbox.
    nonisolated let baseOutputDirectory: URL

    // MARK: - Bitrate Lookup

    /// Returns the average bitrate for the given resolution and frame rate.
    ///
    /// Performs an exact key lookup first; falls back to a resolution-bucket heuristic
    /// if the key is absent (covers slight frame-rate variations and unlisted resolutions).
    ///
    /// The fallback value is a conservative estimate — prefer calibrated table entries.
    ///
    /// - Parameters:
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - fps: Frames per second.
    /// - Returns: Average bitrate in bits per second (always positive).
    nonisolated func averageBitrate(forWidth width: Int, height: Int, fps: Int) -> Int {
        let queryKey = BitrateKey(width: width, height: height, fps: fps)

        // Exact match first (linear scan; table is O(10) entries).
        if let exact = self.bitrateTable.first(where: { $0.key == queryKey }) {
            return exact.value
        }

        // Fallback: find the entry whose pixel count is closest to the requested one
        // and whose fps matches. If no fps match, use the entry with the closest pixel
        // count regardless of fps and scale linearly by the fps ratio.
        let pixelCount = width * height
        let fpsBucket = self.bitrateTable
            .filter { $0.key.fps == fps }
            .min { abs($0.key.pixelCount - pixelCount) < abs($1.key.pixelCount - pixelCount) }

        if let match = fpsBucket {
            // Scale linearly from the closest same-fps entry by pixel-count ratio.
            let ratio = Double(pixelCount) / Double(max(1, match.key.pixelCount))
            return max(1_000_000, Int(Double(match.value) * ratio))
        }

        // No same-fps entry either — scale from any closest entry by both pixel and fps.
        let anyBucket = self.bitrateTable
            .min { abs($0.key.pixelCount - pixelCount) < abs($1.key.pixelCount - pixelCount) }

        if let match = anyBucket {
            let pixelRatio = Double(pixelCount) / Double(max(1, match.key.pixelCount))
            let fpsRatio = Double(fps) / Double(max(1, match.key.fps))
            return max(1_000_000, Int(Double(match.value) * pixelRatio * fpsRatio))
        }

        // Table is empty — hard fallback.
        return 10_000_000
    }

    // MARK: - Default Profile

    /// The canonical MVP recording policy.
    ///
    /// Codec/container/color settings are fixed (AC-4). Numeric bitrate values are
    /// calibration placeholders (see type-level doc). The default profile targets ≤4K60
    /// per AC-5. Its `budgetCap` is the flat 995M px/s AC-5 value, retained only for
    /// consumers that don't route through per-chip-tier budgeting — coupled-quality (AC-Q9)
    /// supersedes plain AC-5 for the device-budget cap: prefer `makeDefault(chipTier:)`,
    /// which sources `budgetCap` from `EngineBudgetCap.budgetCap(for:codec:)` instead.
    ///
    /// Bitrate table placeholder values (bits per second):
    /// - 4K (3840×2160) @ 60 fps  : 60 Mbps average  (industry reference: ~50–80 Mbps HEVC)
    /// - 4K (3840×2160) @ 30 fps  : 36 Mbps average
    /// - 1080p (1920×1080) @ 60 fps: 18 Mbps average
    /// - 1080p (1920×1080) @ 30 fps: 12 Mbps average
    /// - 1440p (2560×1440) @ 60 fps: 28 Mbps average
    /// These MUST be re-calibrated against hardware before MVP ship.
    nonisolated static let mvpDefault = Self.makeMVPDefault()

    // MARK: - Private factory

    /// Builds the canonical MVP default value with an optional custom base output directory.
    ///
    /// Extracted into a named `nonisolated static func` so that the function body is
    /// explicitly `nonisolated`. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `NonisolatedNonsendingByDefault`, a closure literal assigned to a `nonisolated static let`
    /// is still inferred as `@MainActor`-isolated, causing a compile error. A named function
    /// carries its `nonisolated` annotation unambiguously through the type-checker.
    ///
    /// - Parameters:
    ///   - baseDirectory: The user-selected base output directory. When `nil`,
    ///     `~/Movies/Onset/` is used as the default.
    ///   - cameraMirror: Whether the recorded camera image is horizontally mirrored. Default
    ///     `false` so `static let mvpDefault` and existing callers compile unchanged.
    ///   - budgetCap: The engine throughput cap. Defaults to the 995M px/s MVP placeholder
    ///     (4K120, spec "CapabilityProbe и pre-flight бюджет") so `static let mvpDefault` and
    ///     existing callers compile unchanged. `makeDefault(chipTier:)` overrides this with the
    ///     per-tier calibrated cap from `EngineBudgetCap.budgetCap(for:codec:)`.
    nonisolated static func makeMVPDefault(
        baseDirectory: URL? = nil,
        cameraMirror: Bool = false,
        budgetCap: EngineBudgetCap = EngineBudgetCap(maxPixelsPerSecond: 995_000_000)
    )
    -> Self {
        // `RecordingOutput.directory()` is the single authoritative source for `~/Movies/Onset/`.
        // It uses `NSHomeDirectory()` internally — a plain Foundation free function with no actor
        // isolation — so it is safe to call from this `nonisolated` context.
        let baseOutputDirectory = baseDirectory ?? RecordingOutput.directory()

        let bitrateTable: [(key: BitrateKey, value: Int)] = [
            (key: BitrateKey(width: 3840, height: 2160, fps: 60), value: 60_000_000),
            (key: BitrateKey(width: 3840, height: 2160, fps: 30), value: 36_000_000),
            (key: BitrateKey(width: 2560, height: 1440, fps: 60), value: 28_000_000),
            (key: BitrateKey(width: 2560, height: 1440, fps: 30), value: 18_000_000),
            (key: BitrateKey(width: 1920, height: 1080, fps: 60), value: 18_000_000),
            (key: BitrateKey(width: 1920, height: 1080, fps: 30), value: 12_000_000),
        ]

        let movieFragmentIntervalSeconds = 4.0
        let diskThresholds = Self.makeDefaultDiskThresholds(movieFragmentIntervalSeconds: movieFragmentIntervalSeconds)

        return Self(
            container: .mp4,
            codec: .hevc,
            sampleEntry: .hvc1,
            profileLevel: .mainAutoLevel,
            colorPrimaries: .rec709,
            transferFunction: .rec709,
            yCbCrMatrix: .rec709,
            bitDepth: 8,
            maxScreenFps: 60,
            minCameraFps: 30,
            cameraMirror: cameraMirror,
            bitrateTable: bitrateTable,
            dataRateLimitsPeakMultiplier: 2.0,
            keyFrameIntervalSeconds: 2.0,
            allowFrameReordering: false,
            pixelFormatPreference: [.biPlanar420v, .biPlanar420f],
            // Audio placeholder values — calibrate post-MVP against real hardware.
            audioSampleRate: 48000,
            audioChannelCount: 1,
            audioBitrate: 128_000,
            movieFragmentInterval: movieFragmentIntervalSeconds,
            // Degraded-state policy placeholders — калибруется post-MVP against real drop rates.
            degradedBackpressureThreshold: 30,
            degradedWindowSeconds: 2.0,
            postStopDropWarningThreshold: 5,
            // Critical-recording-signals placeholders live as property defaults on the stored
            // properties themselves (single source of truth) — calibrate post-MVP via L5 (MX Brio).
            budgetCap: budgetCap,
            diskThresholds: diskThresholds,
            baseOutputDirectory: baseOutputDirectory
        )
    }

    /// Builds the MVP default configuration with the engine budget cap set from the detected
    /// chip tier (AC-Q9 injection seam), instead of the static 995M MVP placeholder.
    ///
    /// - Parameters:
    ///   - chipTier: The detected Apple Silicon chip tier driving the throughput cap
    ///     (`EngineBudgetCap.budgetCap(for:codec:)`).
    ///   - baseDirectory: Forwarded to `makeMVPDefault`.
    ///   - cameraMirror: Forwarded to `makeMVPDefault`.
    nonisolated static func makeDefault(
        chipTier: ChipTier,
        baseDirectory: URL? = nil,
        cameraMirror: Bool = false
    )
    -> Self {
        self.makeMVPDefault(
            baseDirectory: baseDirectory,
            cameraMirror: cameraMirror,
            budgetCap: EngineBudgetCap.budgetCap(for: chipTier, codec: .hevc)
        )
    }

    /// Builds the default disk-space monitoring thresholds (#88).
    ///
    /// Reasoned defaults, not yet calibrated (AC-10/L5). Split out of `makeMVPDefault` purely to
    /// keep that function's body under the strict `function_body_length` budget.
    ///
    /// - Parameter movieFragmentIntervalSeconds: Sizes `ewmaTimeConstantSeconds` (≥ 4×) and
    ///   `readEverySeconds` (≈ 1×).
    nonisolated static func makeDefaultDiskThresholds(movieFragmentIntervalSeconds: Double) -> DiskThresholds {
        let bytesPerGB: Int64 = 1_000_000_000
        // EWMA window ≥ 4× movieFragmentInterval (~16s): the smoothed slope reflects ≥ 4 reads.
        let ewmaTimeConstantSeconds = 4.0 * movieFragmentIntervalSeconds
        return DiskThresholds(
            // System warn ≤10GB / stop ≤5GB; output warn ETA≤10min|≤10GB / stop ETA≤2min|≤2GB.
            systemWarnBytes: 10 * bytesPerGB,
            systemStopBytes: 5 * bytesPerGB,
            outputWarnBytes: 10 * bytesPerGB,
            outputStopBytes: 2 * bytesPerGB,
            outputWarnEtaSeconds: 10 * 60,
            outputStopEtaSeconds: 2 * 60,
            ewmaTimeConstantSeconds: ewmaTimeConstantSeconds,
            readEverySeconds: movieFragmentIntervalSeconds,
            // Warmup spans the full smoothing window before the EWMA slope is trusted.
            warmupSeconds: ewmaTimeConstantSeconds,
            // Hysteresis release margin (0.5 GB) + de-escalation debounce (~2 read cycles).
            hysteresisReleaseBytes: bytesPerGB / 2,
            deescalationDebounceSeconds: 2 * movieFragmentIntervalSeconds
        )
    }
}

extension RecordingConfiguration: Equatable {
    /// Manual `nonisolated` implementation.
    nonisolated static func == (lhs: RecordingConfiguration, rhs: RecordingConfiguration) -> Bool {
        // Tuples are not `Equatable` in Swift, so compare bitrateTable element-by-element.
        let bitrateTablesEqual = lhs.bitrateTable.count == rhs.bitrateTable.count
            && zip(lhs.bitrateTable, rhs.bitrateTable).allSatisfy { leftEntry, rightEntry in
                leftEntry.key == rightEntry.key && leftEntry.value == rightEntry.value
            }
        return lhs.container == rhs.container
            && lhs.codec == rhs.codec
            && lhs.sampleEntry == rhs.sampleEntry
            && lhs.profileLevel == rhs.profileLevel
            && lhs.colorPrimaries == rhs.colorPrimaries
            && lhs.transferFunction == rhs.transferFunction
            && lhs.yCbCrMatrix == rhs.yCbCrMatrix
            && lhs.bitDepth == rhs.bitDepth
            && lhs.maxScreenFps == rhs.maxScreenFps
            && lhs.minCameraFps == rhs.minCameraFps
            && lhs.cameraMirror == rhs.cameraMirror
            && bitrateTablesEqual
            && lhs.dataRateLimitsPeakMultiplier == rhs.dataRateLimitsPeakMultiplier
            && lhs.keyFrameIntervalSeconds == rhs.keyFrameIntervalSeconds
            && lhs.allowFrameReordering == rhs.allowFrameReordering
            && lhs.pixelFormatPreference == rhs.pixelFormatPreference
            && lhs.audioSampleRate == rhs.audioSampleRate
            && lhs.audioChannelCount == rhs.audioChannelCount
            && lhs.audioBitrate == rhs.audioBitrate
            && lhs.movieFragmentInterval == rhs.movieFragmentInterval
            && lhs.degradedBackpressureThreshold == rhs.degradedBackpressureThreshold
            && lhs.degradedWindowSeconds == rhs.degradedWindowSeconds
            && lhs.postStopDropWarningThreshold == rhs.postStopDropWarningThreshold
            && lhs.criticalSustainSeconds == rhs.criticalSustainSeconds
            && lhs.criticalDropRatePerMin == rhs.criticalDropRatePerMin
            && lhs.criticalDropRateMinSessionSeconds == rhs.criticalDropRateMinSessionSeconds
            && lhs.fpsCollapseRatio == rhs.fpsCollapseRatio
            && lhs.fpsCollapseWindowSeconds == rhs.fpsCollapseWindowSeconds
            && lhs.fpsCollapseGapMsThreshold == rhs.fpsCollapseGapMsThreshold
            && lhs.cameraBaselineWindowSeconds == rhs.cameraBaselineWindowSeconds
            && lhs.cameraBaselineSkipSeconds == rhs.cameraBaselineSkipSeconds
            && lhs.criticalNotificationDedupeSeconds == rhs.criticalNotificationDedupeSeconds
            && lhs.budgetCap == rhs.budgetCap
            && lhs.baseOutputDirectory == rhs.baseOutputDirectory
            && lhs.diskThresholds == rhs.diskThresholds
    }
}

// swiftlint:enable no_magic_numbers
