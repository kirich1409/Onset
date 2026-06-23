import CoreGraphics
@testable import Onset
import Testing

// MARK: - Helpers

private func makeDisplay(
    displayID: CGDirectDisplayID = 1,
    pixelWidth: Int,
    pixelHeight: Int,
    refreshHz: Double
)
-> Display {
    Display(
        displayID: displayID,
        name: "Test Display",
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        refreshHz: refreshHz
    )
}

private func makeCamera(pixelWidth: Int32, pixelHeight: Int32, maxFps: Double) -> CameraFormat {
    CameraFormat(pixelWidth: pixelWidth, pixelHeight: pixelHeight, minFps: 1.0, maxFps: maxFps)
}

// MARK: - CapabilityResolver tests

// type_body_length: single-concern suite covering all CapabilityResolver pure-math paths;
// kept in one struct so the shared `config` fixture is visible everywhere.
// swiftlint:disable type_body_length
@Suite("CapabilityResolver.resolveStartProfile — pure budget math")
struct CapabilityResolverTests {
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - 4K60 single display, no camera

    @Test("4K60 display without camera fits as-is — no downscale")
    func resolve_4K60_noCamera_fitsWithoutDownscale() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        #expect(plan.screenWidth == 3840)
        #expect(plan.screenHeight == 2160)
        #expect(plan.screenFps == 60)
        #expect(plan.cameraPlan == nil)
        // Invariant: dimensions are even
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))
        // Invariant: combined rate fits budget
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    // MARK: - 5K display + camera exceeds budget

    @Test("5K60 display + 1080p30 camera — screen downscaled from 5K, dims even, fits budget")
    func resolve_5K60_1080p30Camera_screenDownscaled() {
        // 5K60 + 1080p30 ≈ 1.01–1.14× budget (spec §"CapabilityProbe и pre-flight бюджет")
        let display = makeDisplay(pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60.0)
        let camera = makeCamera(pixelWidth: 1920, pixelHeight: 1080, maxFps: 30.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: camera,
            config: self.config
        )

        // Screen must have been reduced from the 5K native resolution
        #expect(plan.screenWidth < 5120)

        // Invariant: dimensions are even
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))

        // Invariant: combined rate fits budget
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)

        // Aspect ratio of downscaled screen ≈ source aspect (16:9 in this case)
        let aspect = Double(plan.screenWidth) / Double(plan.screenHeight)
        #expect(abs(aspect - 16.0 / 9.0) < 0.1)

        // Camera plan must be present and reflect the chosen format
        guard let cameraPlan = plan.cameraPlan else {
            Issue.record("Expected a camera plan, but got nil")
            return
        }
        #expect(cameraPlan.width == 1920)
        #expect(cameraPlan.height == 1080)
        #expect(cameraPlan.fps == 30)
    }

    // MARK: - Evenness is always applied

    @Test("Odd-height display — resolved height is even")
    func resolve_oddHeight_resultIsEven() {
        // 2879 is odd — resolver must floor to 2878 (or any smaller even number)
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2879, refreshHz: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        #expect(plan.screenHeight.isMultiple(of: 2))
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    @Test("Odd-width display — resolved width is even")
    func resolve_oddWidth_resultIsEven() {
        let display = makeDisplay(pixelWidth: 1919, pixelHeight: 1080, refreshHz: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))
    }

    // MARK: - Downscale resolution is PRIMARY; fps 60→30 is secondary

    // Spec AC-5 / §"CapabilityProbe и pre-flight бюджет":
    //   PRIMARY lever  — downscale screen resolution at the capped fps to fit budget.
    //   SECONDARY lever — fps 60→30 "при необходимости", only after downscale, last resort.
    //
    // For a 4K60 display + 4096×2160@60 camera (combined 1028M > 995M budget):
    //   Camera rate: 4096×2160×60 = 530_841_600
    //   Remainder for screen at fps=60: 995M − 530M ≈ 464M px/s
    //   Downscale solver: h = floor(sqrt(464M/60 / (16/9))) ≈ 2085, w = floor(2085 × 16/9) ≈ 3706
    //   Solver emits 3708×2086 (exact integer arithmetic may vary by ±2 via even-floor).
    //   Combined: 3708×2086×60 + 530M ≈ 994M ≤ 995M ✓
    //
    // The spec-load-bearing assertions: fps stays 60, resolution is below 4K.
    @Test("4K60 display + over-budget camera — resolution downscaled at fps=60 (PRIMARY lever)")
    func resolve_overBudget_resolutionDownscaledAt60fps() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        // 4096×2160@60 → 530_841_600 px/s; combined with 4K60 → 1_028M > 995M budget.
        let bigCamera = makeCamera(pixelWidth: 4096, pixelHeight: 2160, maxFps: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: bigCamera,
            config: self.config
        )

        // PRIMARY: fps must remain at the capped value (60), NOT dropped to 30.
        #expect(plan.screenFps == 60)
        // PRIMARY: resolution must have been downscaled below 4K.
        #expect(plan.screenWidth < 3840)
        // Exact solver output (even-floored): 3708×2086@60.
        #expect(plan.screenWidth == 3708)
        #expect(plan.screenHeight == 2086)
        // Budget invariant
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
        // Aspect ratio ≈ 16:9
        let aspect = Double(plan.screenWidth) / Double(plan.screenHeight)
        #expect(abs(aspect - 16.0 / 9.0) < 0.05)
        // Even dims
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))
    }

    // MARK: - built-in display (refreshHz == 0)

    @Test("Built-in display (refreshHz 0) resolves to maxScreenFps — not zero fps")
    func resolve_builtInDisplay_zeroRefreshHz_usesMaxFps() {
        // CGDisplayMode.refreshRate returns 0.0 for Apple built-in displays.
        // The resolver must treat this as "unknown / variable" and default to maxScreenFps.
        let display = makeDisplay(pixelWidth: 3456, pixelHeight: 2234, refreshHz: 0.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        #expect(plan.screenFps == self.config.maxScreenFps)
        #expect(plan.screenFps > 0)
    }

    // MARK: - fps capped at maxScreenFps

    @Test("144Hz display fps is capped to maxScreenFps (60)")
    func resolve_144Hz_cappedTo60() {
        let display = makeDisplay(pixelWidth: 2560, pixelHeight: 1440, refreshHz: 144.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        #expect(plan.screenFps == 60)
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    // MARK: - Budget invariant across all plans

    @Test("Budget invariant: combinedPixelsPerSecond ≤ engine ceiling for 4K60 + no camera")
    func budgetInvariant_4K60_noCamera() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    @Test("Budget invariant: combinedPixelsPerSecond ≤ engine ceiling for 5K60 + 1080p30")
    func budgetInvariant_5K60_1080p30() {
        let display = makeDisplay(pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60.0)
        let camera = makeCamera(pixelWidth: 1920, pixelHeight: 1080, maxFps: 30.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: camera,
            config: self.config
        )
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    @Test("Budget invariant: combinedPixelsPerSecond ≤ engine ceiling for 4K60 + large-camera downscale case")
    func budgetInvariant_4K60_largeCamera_downscale() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let bigCamera = makeCamera(pixelWidth: 4096, pixelHeight: 2160, maxFps: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: bigCamera,
            config: self.config
        )
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
    }

    // MARK: - Camera alone exhausts budget

    @Test("Camera alone exhausts budget — screen floored to minimum even size")
    func resolve_cameraAloneExceedsBudget_screenFlooredToMin() {
        // 8K60 camera: 7680×4320@60 ≈ 1_990_656_000 px/s > 995_000_000 budget.
        // After capping camera fps to maxScreenFps (60), camera rate alone exceeds the budget.
        // Screen must be floored to the minimum even dimension (2×2) on both axes.
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let hugeCamera = makeCamera(pixelWidth: 7680, pixelHeight: 4320, maxFps: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: hugeCamera,
            config: self.config
        )

        // Screen must be at the minimum even floor — camera alone consumes all budget.
        #expect(plan.screenWidth == 2)
        #expect(plan.screenHeight == 2)
        // Dimensions remain even.
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))
    }

    // MARK: - No camera — cameraPlan is nil

    @Test("No camera format — cameraPlan is nil")
    func resolve_noCamera_cameraPlanIsNil() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        #expect(plan.cameraPlan == nil)
    }

    // MARK: - Camera plan preserves format dimensions

    @Test("Camera plan mirrors the provided CameraFormat dimensions and clamped fps")
    func resolve_cameraFormat_planMirrorsFormat() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 30.0)
        let camera = makeCamera(pixelWidth: 1280, pixelHeight: 720, maxFps: 30.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: camera,
            config: self.config
        )

        guard let cameraPlan = plan.cameraPlan else {
            Issue.record("Expected a camera plan, but got nil")
            return
        }
        #expect(cameraPlan.width == 1280)
        #expect(cameraPlan.height == 720)
        #expect(cameraPlan.fps == 30)
    }

    // MARK: - displayID is preserved

    @Test("displayID is carried through to the plan")
    func resolve_displayID_preserved() {
        let display = makeDisplay(displayID: 42, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        #expect(plan.displayID == 42)
    }

    // MARK: - 4K camera + 4K screen fits budget without screen downscale

    // Budget arithmetic (deliberate acceptance; see CapabilityResolver.swift step-2 comment):
    //   Budget cap = 995M px/s.
    //   Camera fps = min(30, maxScreenFps=60) = 30 → camera rate = 3840×2160×30 ≈ 248.8M px/s.
    //   Screen rate = 3840×2160×60 ≈ 497.7M px/s.
    //   Combined ≈ 746.5M < 995M → ~25% headroom → screen is NOT downscaled.
    //
    //   Camera fps=30 (not 60) is load-bearing: a 4K@60 camera would contribute 497.7M,
    //   pushing the total to ≈ 995.3M > 995M and triggering a one-step downscale.

    @Test("4K@30 camera + 4K@60 screen fits budget — screen not downscaled")
    func resolve_4K30Camera_4K60Screen_fitsWithoutDownscale() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        // maxFps: 30 — matches the Brio 4K@30 announcement; do NOT use 60 (see knife-edge above).
        let camera = makeCamera(pixelWidth: 3840, pixelHeight: 2160, maxFps: 30.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: camera,
            config: self.config
        )

        // Screen must NOT be downscaled — the 4K@30 camera fits within the budget headroom.
        #expect(plan.screenWidth == 3840)
        #expect(plan.screenHeight == 2160)
        // Budget invariant holds.
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
        // Sanity: even dimensions preserved.
        #expect(plan.screenWidth.isMultiple(of: 2))
        #expect(plan.screenHeight.isMultiple(of: 2))
    }
}
// swiftlint:enable type_body_length
