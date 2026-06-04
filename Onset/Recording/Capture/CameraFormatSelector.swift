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
/// ## Selection algorithm (AC-5 / spec § "РЕШЕНО" ~line 227)
/// 1. Keep only formats where `maxFps ≥ minFps` (≥ 30 by policy).
///    Formats with maxFps below the threshold are excluded even if they offer higher
///    resolution — silently recording at sub-30fps would violate the AC-5 invariant.
///    Note: 29.97 NTSC formats are deliberately excluded by the strict ≥ comparison.
/// 2. Among qualifying formats, pick the one with the largest pixel count (width × height).
/// 3. Tie on pixel count → pick the larger `maxFps`.
///
/// All members are `nonisolated` (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated enum CameraFormatSelector {
    /// Picks the best camera capture format from a pre-discovered list.
    ///
    /// - Parameters:
    ///   - formats: The formats advertised by the camera at enumeration time.
    ///     Pass `CameraDevice.formats` directly.
    ///   - minFps: The minimum acceptable frame rate. Pass
    ///     `Double(config.minCameraFps)` (= 30 for the MVP default profile).
    /// - Returns: The highest-resolution format that supports `maxFps ≥ minFps`.
    ///   On a tie in resolution, the format with the higher `maxFps` is returned.
    /// - Throws: `RecordingError.noSuitableCameraFormat` when no format satisfies
    ///   `maxFps ≥ minFps`, or when `formats` is empty.
    nonisolated static func pickBestFormat(
        from formats: [CameraFormat],
        minFps: Double
    ) throws
    -> CameraFormat {
        // Int32 → Int conversion hoisted to avoid overflow traps under STRICT_MEMORY_SAFETY
        // when multiplying high-resolution dimensions (e.g. 8K is ~33M pixels — within Int32
        // range, but conversion keeps the comparator arithmetic in Int for safety and clarity).
        let qualified = formats.filter { $0.maxFps >= minFps }

        guard let best = qualified.max(by: { lhs, rhs in
            let lPixels = Int(lhs.pixelWidth) * Int(lhs.pixelHeight)
            let rPixels = Int(rhs.pixelWidth) * Int(rhs.pixelHeight)
            if lPixels != rPixels { return lPixels < rPixels }
            return lhs.maxFps < rhs.maxFps
        }) else {
            throw RecordingError.noSuitableCameraFormat
        }

        return best
    }
}
