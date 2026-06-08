/// Camera format auto-pick and mode enumeration for a discovered camera.
///
/// This is a pure, synchronous namespace — it operates on already-enumerated
/// `[CameraFormat]` values (produced by U0.3 device discovery) and carries no hardware access.
///
/// ## Composition seam
/// - **Upstream:** U0.3 (`CameraDeviceDiscovery`) produces `CameraDevice.formats`.
/// - **Downstream:** `pickBestFormat` / `resolveFormat` are called by `MainViewModel+Record`
///   to select the format to pass to `CameraSource`. `availableModes` is called by
///   `MainViewModel` to populate the user-facing mode list.
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

    /// Enumerates the distinct user-selectable camera modes from a format list.
    ///
    /// Returns one `CameraMode` per distinct resolution (pixel width × pixel height),
    /// using the highest fps within the policy-valid band `[config.minCameraFps, config.maxScreenFps]`
    /// for that resolution. Resolutions whose best qualifying fps falls outside the band are
    /// excluded — they cannot be recorded at the policy fps floor and must not appear in the UI.
    ///
    /// Results are sorted by descending pixel count (highest resolution first) for a
    /// consistent, stable ordering across calls.
    ///
    /// - Parameters:
    ///   - formats: The formats advertised by the camera at enumeration time.
    ///     Pass `CameraDevice.formats` directly.
    ///   - config: Recording policy providing `minCameraFps` and `maxScreenFps` for the
    ///     policy-valid fps band.
    /// - Returns: Deduplicated modes sorted by pixel count descending.
    ///   Empty when `formats` is empty or no format meets the policy fps band.
    nonisolated static func availableModes(
        from formats: [CameraFormat],
        config: RecordingConfiguration
    )
    -> [CameraMode] {
        let minFps = Double(config.minCameraFps)
        let maxFps = Double(config.maxScreenFps)

        // Two parallel maps keyed by a packed UInt64 encoding (width, height):
        // - bestFps: the highest policy-valid fps seen per resolution.
        // - dims: the corresponding (width, height) pair for that resolution.
        // Tuple keys cannot be used as Dictionary keys (not Hashable), hence the UInt64 packing.
        var bestFps: [UInt64: Double] = [:]
        var dims: [UInt64: (pixelWidth: Int32, pixelHeight: Int32)] = [:]
        for format in formats {
            // Apply policy band: format must support at least minFps.
            guard format.maxFps >= minFps else { continue }
            // Clamp the offered fps to maxScreenFps — the mode's fps must stay within budget.
            let effectiveFps = min(format.maxFps, maxFps)
            // Pack two Int32 values into one UInt64 key (upper 32: width, lower 32: height).
            let key = (UInt64(bitPattern: Int64(format.pixelWidth)) << 32)
                | UInt64(bitPattern: Int64(format.pixelHeight))
            if bestFps[key].map({ effectiveFps > $0 }) ?? true {
                bestFps[key] = effectiveFps
                dims[key] = (format.pixelWidth, format.pixelHeight)
            }
        }

        let modes: [CameraMode] = bestFps.keys.compactMap { key -> CameraMode? in
            guard let fps = bestFps[key], let dim = dims[key] else { return nil }
            return CameraMode(pixelWidth: dim.pixelWidth, pixelHeight: dim.pixelHeight, fps: Int(fps))
        }

        // Sort by descending pixel count; stable (deterministic) for equal counts.
        return modes.sorted { lhs, rhs in
            let lhsPixels = Int(lhs.pixelWidth) * Int(lhs.pixelHeight)
            let rhsPixels = Int(rhs.pixelWidth) * Int(rhs.pixelHeight)
            if lhsPixels != rhsPixels { return lhsPixels > rhsPixels }
            // Tie-break by fps descending, then width descending for determinism.
            if lhs.fps != rhs.fps { return lhs.fps > rhs.fps }
            return lhs.pixelWidth > rhs.pixelWidth
        }
    }

    /// Resolves the camera format and explicit target fps for a recording session.
    ///
    /// - When `override` is `nil` (Auto mode), delegates to `pickBestFormat` and derives
    ///   fps as `min(Int(format.maxFps), config.maxScreenFps)` — byte-identical to the
    ///   existing auto-pick path.
    /// - When `override` is non-nil, looks for a format whose resolution matches the
    ///   mode's `pixelWidth`/`pixelHeight` and whose `maxFps` satisfies the mode's `fps`.
    ///   The returned fps is `min(mode.fps, config.maxScreenFps)` so a persisted fps that
    ///   exceeds the current policy ceiling (e.g. saved on a different device or policy) is
    ///   silently clamped. If the clamped fps falls below `config.minCameraFps`, or if no
    ///   matching format is found, falls back to the auto-pick path.
    ///
    /// - Parameters:
    ///   - formats: The formats advertised by the camera at enumeration time.
    ///   - override: The user's selected `CameraMode`, or `nil` for Auto.
    ///   - config: Recording policy providing `minCameraFps` and `maxScreenFps`.
    /// - Returns: The chosen `CameraFormat` and the explicit target fps to use for
    ///   `findMatchingFormat` and `activateFormat` in `CameraSource`.
    /// - Throws: `RecordingError.noSuitableCameraFormat` when no usable format exists.
    nonisolated static func resolveFormat(
        from formats: [CameraFormat],
        override: CameraMode?,
        config: RecordingConfiguration
    )
    throws -> (format: CameraFormat, fps: Int) {
        // Auto path — behavior identical to what existed before mode support.
        guard let mode = override else {
            return try self.autoPickResult(from: formats, config: config)
        }

        // Override path — find a format matching the mode's resolution and fps.
        let candidate = formats.first { fmt in
            fmt.pixelWidth == mode.pixelWidth
                && fmt.pixelHeight == mode.pixelHeight
                && fmt.maxFps >= Double(mode.fps)
        }

        if let format = candidate {
            // Bound the persisted fps to the current policy ceiling.
            // A mode saved on a different device or an older policy could carry an fps value
            // above config.maxScreenFps — clamp it so budget and capture always agree.
            let boundedFps = min(mode.fps, config.maxScreenFps)
            // If the bounded fps drops below the policy floor, fall through to auto.
            if boundedFps >= config.minCameraFps {
                return (format, boundedFps)
            }
        }

        // Override format not found (camera changed, format disappeared) — fall back to auto.
        return try self.autoPickResult(from: formats, config: config)
    }

    /// Runs the auto-pick path: picks the best format and derives fps as
    /// `min(Int(format.maxFps), maxScreenFps)`.
    ///
    /// Both the `guard`-else branch of `resolveFormat` (nil override) and its override-not-found
    /// fallback share this computation — extracted to guarantee the derivation is never duplicated.
    nonisolated private static func autoPickResult(
        from formats: [CameraFormat],
        config: RecordingConfiguration
    )
    throws -> (format: CameraFormat, fps: Int) {
        let format = try self.pickBestFormat(
            from: formats,
            minFps: Double(config.minCameraFps)
        )
        // Fps derivation: min(format.maxFps, maxScreenFps) — same as CapabilityResolver auto-path.
        let fps = min(Int(format.maxFps), config.maxScreenFps)
        return (format, fps)
    }

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
