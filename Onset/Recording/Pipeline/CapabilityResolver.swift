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
    ///   - cameraTargetFps: The explicit frame rate for the selected camera mode, or `nil`
    ///     for the auto-pick path (which derives fps as `min(format.maxFps, maxScreenFps)`).
    ///     When non-nil, this value is used for both the budget calculation and the camera
    ///     plan so the budget math is consistent with the format-activation step in
    ///     `CameraSource`. Ignored when `cameraFormat` is `nil`.
    ///   - config: The recording policy (budget cap, fps limits).
    /// - Returns: A `ScreenProfileResolution` with the resolved plan and the
    ///   `budgetExceeded` flag.
    nonisolated static func resolve(
        display: Display,
        cameraFormat: CameraFormat?,
        cameraTargetFps: Int? = nil,
        config: RecordingConfiguration
    )
    -> ScreenProfileResolution {
        // --- Step 1: cap ---
        var capped = Self.clampScreen(display: display, config: config)

        // Camera pixel-rate (0 when no camera). The effective fps is derived ONCE and used
        // in both cameraRateInfo and cameraDimensions to guarantee consistency.
        let (cameraFps, cameraRate) = Self.cameraRateInfo(
            cameraFormat: cameraFormat,
            targetFps: cameraTargetFps,
            config: config
        )
        let cap = config.budgetCap
        let cameraDims = Self.cameraDimensions(
            cameraFormat: cameraFormat,
            effectiveFps: cameraFps
        )

        // `exceedsBudgetAtCap` is computed here — before any lever —
        // because this is the flag the probe needs to classify `.budgetExceeded`.
        let cappedDims = SourceDimensions(width: capped.width, height: capped.height, fps: capped.fps)
        let exceedsBudgetAtCap = !cap.fits(screen: cappedDims, camera: cameraDims)

        // --- Step 2: downscale resolution at the capped fps (PRIMARY lever) ---
        // Spec: "downscale экрана до вписывания, дефолт ≤ 4K60" — resolution is reduced
        // while preserving the capped fps. The raw scalar arithmetic is kept here: the
        // solver legitimately needs the scalar values (budget remainder, pixel count,
        // sqrt aspect-solve) — not the boolean predicate.
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

        let cameraPlan = Self.buildCameraPlan(cameraFormat: cameraFormat, fps: cameraFps)

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
    ///   - cameraTargetFps: The explicit frame rate for the selected camera mode, or `nil`
    ///     for the auto-pick path. See `resolve(display:cameraFormat:cameraTargetFps:config:)`.
    ///   - config: The recording policy (budget cap, fps limits).
    /// - Returns: A `ResolvedRecordingPlan` with even dimensions and a budget-respecting
    ///   pixel-rate. Use `ResolvedRecordingPlan.combinedPixelsPerSecond` and
    ///   `RecordingConfiguration.budgetCap.fits(screen:camera:)` in U1.2 to decide
    ///   whether the plan is hardware-feasible.
    nonisolated static func resolveStartProfile(
        display: Display,
        cameraFormat: CameraFormat?,
        cameraTargetFps: Int? = nil,
        config: RecordingConfiguration
    )
    -> ResolvedRecordingPlan {
        self.resolve(
            display: display,
            cameraFormat: cameraFormat,
            cameraTargetFps: cameraTargetFps,
            config: config
        ).plan
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

    /// Returns the camera's pixel-rate and effective fps.
    ///
    /// When `targetFps` is non-nil (user's CameraMode override), it is used directly
    /// (clamped to `config.maxScreenFps` for safety). When nil (Auto path), fps is
    /// `min(Int(format.maxFps), config.maxScreenFps)` — byte-identical to the pre-mode behavior.
    ///
    /// `Int(Double)` truncates fractional Hz (e.g. 29.97 → 29); callers should supply
    /// formats whose maxFps is a clean integer value when possible.
    /// Explicit-typed intermediates avoid `Optional.map { <arithmetic> }` type-checker timeouts.
    nonisolated private static func cameraRateInfo(
        cameraFormat: CameraFormat?,
        targetFps: Int?,
        config: RecordingConfiguration
    )
    -> (fps: Int, rate: Int) {
        guard let format = cameraFormat else { return (fps: 0, rate: 0) }
        // Honor the user's mode selection when provided; clamp to the policy ceiling.
        // Auto path: derive from format's max fps (pre-mode behavior, min(maxFps, maxScreenFps)).
        let fps: Int = if let explicit = targetFps {
            min(explicit, config.maxScreenFps)
        } else {
            min(Int(format.maxFps), config.maxScreenFps)
        }
        let rate = Int(format.pixelWidth) * Int(format.pixelHeight) * fps
        return (fps: fps, rate: rate)
    }

    /// Returns camera capture dimensions as `SourceDimensions` for use with
    /// `EngineBudgetCap.fits(screen:camera:)`.
    ///
    /// Takes `effectiveFps` (pre-computed by `cameraRateInfo`) to guarantee the fps used in
    /// the rate check (`cap.fits`) is identical to the fps used in the pixel-rate arithmetic —
    /// never derive fps independently in two places.
    ///
    /// When `cameraFormat` is `nil`, returns a zero-rate sentinel so the boolean predicate
    /// produces the same result as the scalar arithmetic (`cameraRate == 0`).
    nonisolated private static func cameraDimensions(
        cameraFormat: CameraFormat?,
        effectiveFps: Int
    )
    -> SourceDimensions {
        guard let format = cameraFormat else { return SourceDimensions(width: 0, height: 0, fps: 0) }
        return SourceDimensions(
            width: Int(format.pixelWidth),
            height: Int(format.pixelHeight),
            fps: effectiveFps
        )
    }

    /// Builds a `ResolvedCameraPlan` with even-floored dimensions for the given format and fps.
    ///
    /// Even-floor is required: HEVC mandates even frame dimensions. AVCaptureDevice formats are
    /// even in practice, but the contract must hold on both sides.
    ///
    /// Hoisted out of `resolve()` into its own helper to satisfy the function-body-length lint
    /// gate: chaining `Int(...) & ~1` inside an initialiser argument also triggers the Swift
    /// type-checker timeout under load (warnings-as-errors → red CI), so explicit `let` bindings
    /// are retained here.
    nonisolated private static func buildCameraPlan(
        cameraFormat: CameraFormat?,
        fps: Int
    )
    -> ResolvedCameraPlan? {
        cameraFormat.map { format in
            let evenCamW: Int = max(Int(format.pixelWidth) & ~1, Self.minEvenDimension)
            let evenCamH: Int = max(Int(format.pixelHeight) & ~1, Self.minEvenDimension)
            return ResolvedCameraPlan(width: evenCamW, height: evenCamH, fps: fps)
        }
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
