import CoreGraphics

// MARK: - CapabilityResolver

/// Pure resolver for the recording start profile.
///
/// Converts a (display, optional camera format, config) triple into a
/// `ResolvedRecordingPlan` that fits the engine budget without hardware access.
///
/// ### Algorithm (spec §"CapabilityProbe и pre-flight бюджет")
///
/// 1. **Cap** — clamp the native display resolution to ≤4K (3840×2160), and fps
///    to ≤`config.maxScreenFps` (60). `Display.refreshHz == 0.0` (built-in displays)
///    is treated as 60 Hz at this stage — 0 is a sentinel for "unknown", not "zero Hz".
///
/// 2. **Budget: fps fallback first** — if the combined pixel-rate exceeds
///    `budgetCap.maxPixelsPerSecond` at the capped fps, try halving the screen fps
///    to `config.minCameraFps` (30). Preferring fps reduction over resolution reduction
///    preserves maximum detail.
///
/// 3. **Budget: sub-4K downscale** — if fps fallback was not enough (or fps is already
///    at the minimum), shrink the screen resolution (preserving aspect ratio) until
///    the combined pixel-rate fits. This is the last resort.
///
/// 4. **Even floor** — screen dimensions are rounded DOWN to the nearest even number on
///    every code path (HEVC requires even frame dimensions).
///
/// The resolver is TOTAL: it always returns a plan. Deciding whether the plan is
/// acceptable for the hardware is U1.2's responsibility (`EngineBudgetCap.fits`).
nonisolated enum CapabilityResolver {
    // MARK: - Constants (spec §"CapabilityProbe и pre-flight бюджет", AC-5)

    /// Maximum screen width the default recording profile targets (≤4K60).
    private static let maxScreenWidth4K = 3840

    /// Maximum screen height the default recording profile targets (≤4K60).
    private static let maxScreenHeight4K = 2160

    /// Minimum even dimension for a down-scaled screen axis (HEVC floor).
    private static let minEvenDimension = 2

    // MARK: - Private types

    /// Capped screen dimensions and fps returned by `clampScreen(display:config:)`.
    private struct ClampedScreen {
        var width: Int
        var height: Int
        var fps: Int
    }

    // MARK: - Entry point

    /// Resolves the concrete start profile for a recording session.
    ///
    /// - Parameters:
    ///   - display: The already-selected display snapshot (from DeviceDiscovery).
    ///   - cameraFormat: The already-selected camera format, or `nil` when no camera is
    ///     used. Format picking (choosing among available formats) is U3.1 / #29 — this
    ///     function receives the result, not the raw list.
    ///   - config: The recording policy (budget cap, fps limits).
    /// - Returns: A `ResolvedRecordingPlan` with even dimensions and a budget-respecting
    ///   pixel-rate. Use `ResolvedRecordingPlan.combinedPixelsPerSecond` and
    ///   `RecordingConfiguration.budgetCap.fits(screen:camera:)` in U1.2 to decide
    ///   whether the plan is hardware-feasible.
    nonisolated static func resolveStartProfile(
        display: Display,
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> ResolvedRecordingPlan {
        // --- Step 1: cap ---
        var capped = Self.clampScreen(display: display, config: config)

        // Camera pixel-rate (0 when no camera).
        let (cameraFps, cameraRate) = Self.cameraRateInfo(cameraFormat: cameraFormat, config: config)
        let cap = config.budgetCap

        // --- Step 2: fps fallback ---
        // Try the minimum fps (config.minCameraFps, typically 30) before downscaling.
        let exceedsBudgetAt60 = capped.width * capped.height * capped.fps + cameraRate > cap.maxPixelsPerSecond
        if exceedsBudgetAt60, capped.fps > config.minCameraFps {
            let rateAtMin = capped.width * capped.height * config.minCameraFps + cameraRate
            if rateAtMin <= cap.maxPixelsPerSecond {
                capped.fps = config.minCameraFps
            }
        }

        // --- Step 3: sub-4K downscale (last resort) ---
        (capped.width, capped.height) = Self.downscaleIfNeeded(
            width: capped.width,
            height: capped.height,
            fps: capped.fps,
            cameraRate: cameraRate,
            cap: cap
        )

        // --- Step 4: floor to even (unconditional) ---
        // HEVC requires even frame dimensions. Applied on every code path.
        let evenWidth = max(capped.width & ~1, Self.minEvenDimension)
        let evenHeight = max(capped.height & ~1, Self.minEvenDimension)

        let cameraPlan: ResolvedCameraPlan? = cameraFormat.map { format in
            ResolvedCameraPlan(
                width: Int(format.pixelWidth),
                height: Int(format.pixelHeight),
                fps: cameraFps
            )
        }

        return ResolvedRecordingPlan(
            displayID: display.displayID,
            screenWidth: evenWidth,
            screenHeight: evenHeight,
            screenFps: capped.fps,
            cameraPlan: cameraPlan
        )
    }

    // MARK: - Helpers

    /// Clamps the display's native resolution to ≤4K and fps to `config.maxScreenFps`.
    ///
    /// `Display.refreshHz == 0.0` is a sentinel for "built-in / variable rate" — treated
    /// as `config.maxScreenFps` (60) rather than zero Hz.
    nonisolated private static func clampScreen(
        display: Display,
        config: RecordingConfiguration
    )
    -> ClampedScreen {
        // refreshHz == 0.0 means "built-in / variable" — use maxScreenFps as the fallback.
        let fps = display.refreshHz == 0.0
            ? config.maxScreenFps
            : min(Int(display.refreshHz), config.maxScreenFps)
        return ClampedScreen(
            width: min(display.pixelWidth, Self.maxScreenWidth4K),
            height: min(display.pixelHeight, Self.maxScreenHeight4K),
            fps: fps
        )
    }

    /// Returns the camera's pixel-rate and target fps for the selected format.
    ///
    /// Camera target fps: maxFps of the selected format, clamped to `config.maxScreenFps`.
    /// `Int(Double)` truncates fractional Hz (e.g. 29.97 → 29); callers should supply
    /// formats whose maxFps is a clean integer value when possible.
    /// Explicit-typed intermediates avoid `Optional.map { <arithmetic> }` type-checker timeouts.
    nonisolated private static func cameraRateInfo(
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> (fps: Int, rate: Int) {
        guard let format = cameraFormat else { return (fps: 0, rate: 0) }
        let fps = min(Int(format.maxFps), config.maxScreenFps)
        let rate = Int(format.pixelWidth) * Int(format.pixelHeight) * fps
        return (fps: fps, rate: rate)
    }

    /// Downscales `width`/`height` (preserving aspect ratio) until the combined pixel-rate
    /// fits within `cap`, or returns `(minEvenDimension, minEvenDimension)` when
    /// the camera alone exhausts the budget.
    nonisolated private static func downscaleIfNeeded(
        width: Int,
        height: Int,
        fps: Int,
        cameraRate: Int,
        cap: EngineBudgetCap
    )
    -> (width: Int, height: Int) {
        guard width * height * fps + cameraRate > cap.maxPixelsPerSecond else {
            return (width, height)
        }
        let budgetForScreen = cap.maxPixelsPerSecond - cameraRate
        guard budgetForScreen > 0, fps > 0 else {
            // Camera alone consumes all budget — floor screen to smallest even size.
            return (Self.minEvenDimension, Self.minEvenDimension)
        }
        // Maximum pixel count the screen may have at the target fps.
        let maxPixels = budgetForScreen / fps
        let aspect = Double(width) / Double(height)
        // h² × aspect = maxPixels → h = sqrt(maxPixels / aspect)
        let newH = max(Int(sqrt(Double(maxPixels) / aspect)), Self.minEvenDimension)
        let newW = max(Int(Double(newH) * aspect), Self.minEvenDimension)
        return (newW, newH)
    }
}
