import CoreGraphics
@testable import Onset
import Testing

// no_magic_numbers is disabled file-wide: these are Swift Testing structs (no XCTest
// parent class), so the rule's `test_parent_classes` exclusion in .swiftlint.yml does
// not apply; the numeric literals here are expected-value test data, not magic numbers.
// swiftlint:disable no_magic_numbers

// MARK: - Helpers

private func makeDisplay(
    displayID: CGDirectDisplayID = 1,
    pixelWidth: Int,
    pixelHeight: Int,
    refreshHz: Double
)
-> Display {
    Display(displayID: displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: refreshHz)
}

private func makeCamera(pixelWidth: Int32, pixelHeight: Int32, maxFps: Double) -> CameraFormat {
    CameraFormat(pixelWidth: pixelWidth, pixelHeight: pixelHeight, minFps: 1.0, maxFps: maxFps)
}

// MARK: - CapabilityResolver tests

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

    // MARK: - fps fallback before resolution downscale

    @Test("fps 60→30 avoids sub-4K downscale when 30fps fits budget")
    func resolve_fpsFallback_60to30_preserves4K() {
        // A 4K display + a large camera whose combined 60fps rate exceeds budget, but
        // the same combination at 30fps fits. The resolver must drop fps before shrinking
        // the screen resolution.
        //
        // 4K60 + 4K60 = 2 × (3840×2160×60) ≈ 995M × 2 — way over budget.
        // 4K30 + 4K60 = 3840×2160×30 + 3840×2160×60 ≈ 995M × 1.5 — still over budget.
        // 4K30 + 1080p30 = 498M + 62M ≈ 560M — well within 995M.
        // Use a camera that is fixed at 60fps and a display where 4K30+cam fits.
        // Camera: 1920×1080@60fps → 124M px/s; 4K30 → 248M px/s; total 373M ≤ 995M.
        // Camera: 3840×2160@60fps → 497M px/s; 4K30 → 248M px/s; total 745M ≤ 995M.
        // Camera: 3840×2160@60fps → 497M; 4K60 → 497M; total 994M ≤ 995M — just fits!
        //
        // Pick a case where 4K60 + camera EXCEEDS but 4K30 + camera FITS:
        // Camera: 1920×1080@60fps → 124_416_000 px/s
        // 4K60: 497_664_000 px/s → total 622_080_000 ≤ 995M (fits even at 60fps)
        //
        // We need a camera large enough that screen@60 + camera > 995M but screen@30 + camera ≤ 995M.
        // Camera: 4096×2160@60fps → 530_841_600; 4K60 → 497M; total 1_027M > 995M (over!)
        //                                          4K30 → 248M; total 779M ≤ 995M (fits!)
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let bigCamera = makeCamera(pixelWidth: 4096, pixelHeight: 2160, maxFps: 60.0)

        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: bigCamera,
            config: self.config
        )

        // FPS must have been dropped to 30 (not the screen downscaled below 4K)
        #expect(plan.screenFps == 30)
        // Screen resolution must still be 4K (only fps dropped, no downscale)
        #expect(plan.screenWidth == 3840)
        #expect(plan.screenHeight == 2160)
        // Budget invariant
        #expect(plan.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
        // Dims even
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

    @Test("Budget invariant: combinedPixelsPerSecond ≤ engine ceiling for 4K60 + large-camera fps-fallback case")
    func budgetInvariant_4K60_largeCamera_fpsFallback() {
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
}

// swiftlint:enable no_magic_numbers
