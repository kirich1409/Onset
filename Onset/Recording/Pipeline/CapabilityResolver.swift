import CoreGraphics

// MARK: - CapabilityResolver

/// Pure resolver for the recording start profile.
///
/// Converts a (display, optional camera format, config) triple into a
/// `ResolvedRecordingPlan` that fits the engine budget without hardware access.
///
/// ### Algorithm (spec §"CapabilityProbe и pre-flight бюджет", AC-5)
///
/// 1. **Cap** — clamp the native display resolution to ≤4K (3840×2160), and fps
///    to `min(display.refreshHz, config.maxScreenFps)` (60). `Display.refreshHz == 0.0`
///    (built-in displays) is treated as `config.maxScreenFps` — 0 is a sentinel for
///    "unknown / variable rate", not "zero Hz".
///
/// 2. **Primary lever — downscale resolution at the capped fps** (spec: "downscale экрана
///    до вписывания, дефолт ≤ 4K60") — if the combined pixel-rate at the capped fps
///    exceeds the engine budget, shrink the screen resolution (preserving aspect ratio,
///    even dims) while keeping the capped fps unchanged. This is the PRIMARY budget lever.
///
/// 3. **Secondary lever — fps 60→30 "if needed"** (spec: "при необходимости fps 60→30") —
///    applied only AFTER the downscale step, as a last resort. In practice the downscale
///    at capped fps fits whenever the camera alone is within budget (the solver shrinks the
///    screen to the 2×2 floor). The fps fallback is therefore reachable only in the
///    camera-dominated corner (camera alone ≥ budget → screen already at 2×2 floor),
///    where it is applied as a best-effort per-spec "if needed". It does not rescue the
///    budget in that corner (camera fps is capped independently; the plan remains
///    `budgetExceeded`), but it records the intent faithfully.
///
/// 4. **Even floor** — screen dimensions are rounded DOWN to the nearest even number on
///    every code path (HEVC requires even frame dimensions).
///
/// The resolver is TOTAL: it always returns a plan. Deciding whether the plan is
/// acceptable for the hardware is U1.2's responsibility (`EngineBudgetCap.fits`).
nonisolated enum CapabilityResolver {
    // MARK: - Constants (spec §"CapabilityProbe и pre-flight бюджет", AC-5)

    /// Maximum screen width the default recording profile targets (≤4K60).
    ///
    /// The ≤4K clamp is edge-protection against hypothetical 5K/6K displays — it is NOT the
    /// MVP target scenario. MVP targets 4K displays; 5K/6K are guarded but not a launch target.
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

    // MARK: - Public result type

    /// The result of `resolve(display:cameraFormat:config:)`.
    ///
    /// Carries the resolved plan together with the budget-classification flag the probe
    /// needs, so the probe can derive `.ok` vs `.budgetExceeded` without re-implementing
    /// the clamp logic.
    nonisolated struct ScreenProfileResolution {
        /// The concrete start profile (downscaled if necessary to fit the budget).
        nonisolated let plan: ResolvedRecordingPlan
        /// `true` when the ≤4K60 clamped baseline (before fps-fallback or downscale)
        /// already exceeded the engine budget — i.e. the resolved plan is reduced.
        nonisolated let budgetExceeded: Bool
    }

    // MARK: - Entry points

    /// Resolves the concrete start profile together with a budget-exceeded flag.
    ///
    /// Prefer this over `resolveStartProfile` when the caller also needs to know whether
    /// the clamped baseline exceeded the budget (e.g. `CapabilityProbe`).
    ///
    /// - Parameters:
    ///   - display: The already-selected display snapshot (from DeviceDiscovery).
    ///   - cameraFormat: The already-selected camera format, or `nil` when no camera is
    ///     used.
    ///   - config: The recording policy (budget cap, fps limits).
    /// - Returns: A `ScreenProfileResolution` with the resolved plan and the
    ///   `budgetExceeded` flag.
    nonisolated static func resolve(
        display: Display,
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> ScreenProfileResolution {
        // --- Step 1: cap ---
        var capped = Self.clampScreen(display: display, config: config)

        // Camera pixel-rate (0 when no camera).
        let (cameraFps, cameraRate) = Self.cameraRateInfo(cameraFormat: cameraFormat, config: config)
        let cap = config.budgetCap
        let cameraDims = Self.cameraDimensions(cameraFormat: cameraFormat, config: config)

        // `exceedsBudgetAtCap` is computed here — before any lever —
        // because this is the flag the probe needs to classify `.budgetExceeded`.
        let cappedDims = SourceDimensions(width: capped.width, height: capped.height, fps: capped.fps)
        let exceedsBudgetAtCap = !cap.fits(screen: cappedDims, camera: cameraDims)

        // --- Step 2: downscale resolution at the capped fps (PRIMARY lever) ---
        // Spec: "downscale экрана до вписывания, дефолт ≤ 4K60" — resolution is reduced
        // while preserving the capped fps. The raw scalar arithmetic is kept here: the
        // solver legitimately needs the scalar values (budget remainder, pixel count,
        // sqrt aspect-solve) — not the boolean predicate.
        //
        // 4K camera + 4K screen budget note (deliberate acceptance):
        //   Budget cap = 995M px/s.  cameraRateInfo uses fps = min(maxFps, maxScreenFps),
        //   so a Brio 4K@30 contributes 3840×2160×30 ≈ 248.8M px/s.
        //   A 4K@60 screen contributes 3840×2160×60 ≈ 497.7M px/s.
        //   Combined ≈ 746.5M < 995M → ~25% headroom → screen is NOT downscaled. ✓
        //
        //   Knife-edge: a hypothetical 4K@60 camera would contribute 497.7M px/s;
        //   combined with a 4K@60 screen ≈ 995.3M > 995M → the screen WOULD be
        //   shaved by one solver step. The Brio announces 4K@30, so it fits cleanly.
        //   If a future 4K@60 camera appears and the screen appears to shrink by a
        //   tiny amount, this is correct resolver behaviour — not a bug.
        (capped.width, capped.height) = Self.downscaleIfNeeded(
            width: capped.width,
            height: capped.height,
            fps: capped.fps,
            cameraRate: cameraRate,
            cap: cap
        )

        // --- Step 3: fps 60→30 (SECONDARY lever, "при необходимости") ---
        // Fires only when the downscaled plan still exceeds budget — i.e. the
        // camera-dominated corner where the screen is already at the 2×2 floor.
        // In that corner the fps fallback does not rescue the budget (camera rate alone
        // exceeds the ceiling; plan is `.budgetExceeded`), but it records the spec's
        // "if needed" intent as a best-effort.
        let downsizedDims = SourceDimensions(width: capped.width, height: capped.height, fps: capped.fps)
        if !cap.fits(screen: downsizedDims, camera: cameraDims), capped.fps > config.minCameraFps {
            capped.fps = config.minCameraFps
        }

        // --- Step 4: floor to even (unconditional) ---
        // HEVC requires even frame dimensions. Applied on every code path.
        let evenWidth = max(capped.width & ~1, Self.minEvenDimension)
        let evenHeight = max(capped.height & ~1, Self.minEvenDimension)

        // FIX 3: apply even-floor to camera dimensions for symmetric HEVC contract enforcement.
        // AVCaptureDevice formats are even in practice, but the contract must hold on both sides.
        // Hoisted into explicit lets: chained Int(...) & ~1 inside an init-call argument triggers
        // the Swift type-checker timeout under load (warnings-as-errors → red CI).
        let cameraPlan: ResolvedCameraPlan? = cameraFormat.map { format in
            let evenCamW: Int = max(Int(format.pixelWidth) & ~1, Self.minEvenDimension)
            let evenCamH: Int = max(Int(format.pixelHeight) & ~1, Self.minEvenDimension)
            return ResolvedCameraPlan(
                width: evenCamW,
                height: evenCamH,
                fps: cameraFps
            )
        }

        let plan = ResolvedRecordingPlan(
            displayID: display.displayID,
            screenWidth: evenWidth,
            screenHeight: evenHeight,
            screenFps: capped.fps,
            cameraPlan: cameraPlan
        )
        return ScreenProfileResolution(plan: plan, budgetExceeded: exceedsBudgetAtCap)
    }

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
        self.resolve(display: display, cameraFormat: cameraFormat, config: config).plan
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

    /// Returns camera capture dimensions as `SourceDimensions` for use with
    /// `EngineBudgetCap.fits(screen:camera:)`.
    ///
    /// When `cameraFormat` is `nil`, returns a zero-rate sentinel so the boolean predicate
    /// produces the same result as the scalar arithmetic (`cameraRate == 0`).
    nonisolated private static func cameraDimensions(
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> SourceDimensions {
        guard let format = cameraFormat else { return SourceDimensions(width: 0, height: 0, fps: 0) }
        return SourceDimensions(
            width: Int(format.pixelWidth),
            height: Int(format.pixelHeight),
            fps: min(Int(format.maxFps), config.maxScreenFps)
        )
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
