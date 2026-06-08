/// Camera format auto-pick: selects the best `CameraFormat` from a discovered list.
///
/// This is a pure, synchronous function — it operates on an already-enumerated
/// `[CameraFormat]` (produced by U0.3 device discovery) and carries no hardware access.
///
/// ## Composition seam
/// - **Upstream:** U0.3 (`CameraDeviceDiscovery`) produces `CameraDevice.formats`.
/// - **Downstream:** #30 (`RecordingPlanResolver`) calls `pickBestFormat` and uses the
///   returned format's `pixelWidth`/`pixelHeight`/`maxFps` to build a `ResolvedRecordingPlan`.
///   The resolver bridges the `Int`-typed fps to `RecordingConfiguration.minCameraFps: Int`
///   by passing `Double(config.minCameraFps)` as the `minFps` argument.
///
/// ## Selection algorithm (issue #145 — 16:9 + Full HD targeting)
/// 1. Keep only formats where `maxFps ≥ minFps` (≥ 30 by policy).
///    Formats with maxFps below the threshold are excluded even if they offer higher
///    resolution — silently recording at sub-30fps would violate the AC-5 invariant.
///    Note: 29.97 NTSC formats are deliberately excluded by the strict ≥ comparison.
/// 2. **Prefer 16:9.** A format is 16:9 when `pixelWidth * 9 == pixelHeight * 16`
///    (exact integer check; covers 1920×1080, 1280×720, 3840×2160, etc.).
/// 3. **Target Full HD (1920×1080).** Among 16:9 qualifying formats, prefer the largest
///    16:9 format whose height ≤ 1080 (so 1080p if offered, else 720p, etc.).
///    If all 16:9 formats exceed 1080p, pick the smallest 16:9 (closest from above).
///    Never pick above 1080p when a ≤ 1080p 16:9 option exists.
/// 4. On the chosen resolution, prefer the higher `maxFps` (60 over 30).
/// 5. **Fallback:** if there are no 16:9 formats among the qualifying set, fall back to
///    the largest pixel count with a tie-break on `maxFps`, so cameras that only offer
///    non-16:9 formats still return a result.
/// 6. Throw `RecordingError.noSuitableCameraFormat` only when the qualifying set is empty.
///
/// All members are `nonisolated` (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated enum CameraFormatSelector {
    // MARK: - Constants

    /// Aspect-ratio numerator for 16:9 (width side).
    private static let aspectRatioWidth = 16

    /// Aspect-ratio denominator for 16:9 (height side).
    private static let aspectRatioHeight = 9

    /// Maximum height (inclusive) for the preferred Full HD resolution tier.
    private static let fullHDMaxHeight = 1080

    // MARK: - Public API

    /// Picks the best camera capture format from a pre-discovered list.
    ///
    /// - Parameters:
    ///   - formats: The formats advertised by the camera at enumeration time.
    ///     Pass `CameraDevice.formats` directly.
    ///   - minFps: The minimum acceptable frame rate. Pass
    ///     `Double(config.minCameraFps)` (= 30 for the MVP default profile).
    /// - Returns: The best 16:9 format targeting Full HD resolution (≤ 1080p) that
    ///   supports `maxFps ≥ minFps`. On a tie in resolution, the format with the higher
    ///   `maxFps` is returned. Falls back to largest pixel count (tie-break: higher
    ///   `maxFps`) when no 16:9 format qualifies.
    /// - Throws: `RecordingError.noSuitableCameraFormat` when no format satisfies
    ///   `maxFps ≥ minFps`, or when `formats` is empty.
    nonisolated static func pickBestFormat(
        from formats: [CameraFormat],
        minFps: Double
    ) throws
    -> CameraFormat {
        let qualified = formats.filter { $0.maxFps >= minFps }

        guard !qualified.isEmpty else {
            throw RecordingError.noSuitableCameraFormat
        }

        let sixteenByNine = qualified.filter { self.isSixteenByNine($0) }

        if sixteenByNine.isEmpty {
            // Fallback: no 16:9 formats — largest pixel count, tie-break on maxFps.
            return self.bestByPixelCount(from: qualified)
        }

        return self.bestSixteenByNineFormat(from: sixteenByNine)
    }

    // MARK: - Helpers

    /// Returns `true` when the format's dimensions are exactly 16:9.
    nonisolated private static func isSixteenByNine(_ format: CameraFormat) -> Bool {
        // Int32 → Int: avoids overflow traps under STRICT_MEMORY_SAFETY for high-res dimensions.
        Int(format.pixelWidth) * self.aspectRatioHeight == Int(format.pixelHeight) * self.aspectRatioWidth
    }

    /// Picks the best format from a non-empty 16:9 set, targeting Full HD (≤ 1080p height).
    ///
    /// - If any format has `height ≤ fullHDMaxHeight`, picks the largest such format
    ///   (highest pixel count within the ≤ 1080p tier), tie-break on higher `maxFps`.
    /// - If all formats exceed 1080p (camera offers no ≤ 1080p 16:9 option), picks the
    ///   smallest format (closest to the target from above), tie-break on higher `maxFps`.
    nonisolated private static func bestSixteenByNineFormat(from formats: [CameraFormat]) -> CameraFormat {
        let belowOrAtFullHD = formats.filter { Int($0.pixelHeight) <= self.fullHDMaxHeight }

        if !belowOrAtFullHD.isEmpty {
            // Prefer the largest resolution that does not exceed Full HD.
            return self.bestByPixelCount(from: belowOrAtFullHD)
        } else {
            // All 16:9 options are above Full HD — pick the smallest (closest to target from above).
            return self.smallestByPixelCount(from: formats)
        }
    }

    /// Returns the format with the largest pixel count (width × height).
    /// On a pixel-count tie, returns the format with the higher `maxFps`.
    /// Precondition: `formats` is non-empty.
    nonisolated private static func bestByPixelCount(from formats: [CameraFormat]) -> CameraFormat {
        formats.reduce(formats[0]) { best, candidate in
            // Int32 → Int: avoids overflow traps under STRICT_MEMORY_SAFETY for high-res dimensions.
            let bestPixels = Int(best.pixelWidth) * Int(best.pixelHeight)
            let candidatePixels = Int(candidate.pixelWidth) * Int(candidate.pixelHeight)
            if candidatePixels != bestPixels { return candidatePixels > bestPixels ? candidate : best }
            return candidate.maxFps > best.maxFps ? candidate : best
        }
    }

    /// Returns the format with the smallest pixel count (width × height).
    /// On a pixel-count tie, returns the format with the higher `maxFps`.
    /// Precondition: `formats` is non-empty.
    nonisolated private static func smallestByPixelCount(from formats: [CameraFormat]) -> CameraFormat {
        formats.reduce(formats[0]) { best, candidate in
            // Int32 → Int: avoids overflow traps under STRICT_MEMORY_SAFETY for high-res dimensions.
            let bestPixels = Int(best.pixelWidth) * Int(best.pixelHeight)
            let candidatePixels = Int(candidate.pixelWidth) * Int(candidate.pixelHeight)
            if candidatePixels != bestPixels { return candidatePixels < bestPixels ? candidate : best }
            return candidate.maxFps > best.maxFps ? candidate : best
        }
    }
}
