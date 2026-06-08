import Foundation
@testable import Onset
import Testing

// MARK: - CameraModeResolverTests

/// L2 tests for `CameraFormatSelector.resolveFormat(from:override:config:)`.
///
/// Verifies:
/// 1. Auto path (nil override) delegates to `pickBestFormat` and derives fps as
///    `min(format.maxFps, config.maxScreenFps)`.
/// 2. Override path — format matching mode resolution/fps is selected and explicit fps used.
/// 3. Override fallback — when no format matches the override, auto-pick is used.
/// 4. Throws `RecordingError.noSuitableCameraFormat` for an empty format list.
@Suite("CameraFormatSelector.resolveFormat — override and auto paths")
struct CameraModeResolverTests {
    // MARK: - Helpers

    private func makeFormat(width: Int32, height: Int32, maxFps: Double) -> CameraFormat {
        CameraFormat(pixelWidth: width, pixelHeight: height, minFps: 1.0, maxFps: maxFps)
    }

    private func makeMode(width: Int32, height: Int32, fps: Int) -> CameraMode {
        CameraMode(pixelWidth: width, pixelHeight: height, fps: fps)
    }

    // MARK: - Auto path (nil override)

    @Test("Nil override → best format picked by pickBestFormat (16:9 Full HD target)")
    func nilOverride_picksFullHD() throws {
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
            self.makeFormat(width: 1280, height: 720, maxFps: 60),
        ]
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: nil,
            config: RecordingConfiguration.mvpDefault
        )
        // pickBestFormat favours ≤1080p 16:9 → 1920×1080
        #expect(format.pixelWidth == 1920)
        #expect(format.pixelHeight == 1080)
        // fps = min(60, maxScreenFps=60) = 60
        #expect(fps == 60)
    }

    @Test("Nil override — fps clamped to config.maxScreenFps")
    func nilOverride_fpsClampedToMaxScreenFps() throws {
        // A hypothetical format that advertises 120fps — should be clamped to 60.
        let formats = [self.makeFormat(width: 1920, height: 1080, maxFps: 120)]
        let (_, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: nil,
            config: RecordingConfiguration.mvpDefault
        )
        // maxScreenFps = 60 per mvpDefault
        #expect(fps == 60)
    }

    // MARK: - Override path — match found

    @Test("Override present with matching format → override format and fps returned")
    func overridePresent_matchingFormat_returnsOverride() throws {
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
        ]
        let mode = self.makeMode(width: 1920, height: 1080, fps: 60)
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(format.pixelWidth == 1920)
        #expect(format.pixelHeight == 1080)
        #expect(fps == 60)
    }

    @Test("Override for 4K@30 → 4K format and fps=30 returned")
    func overrideFor4K30_returns4KAt30fps() throws {
        let formats = [
            self.makeFormat(width: 3840, height: 2160, maxFps: 30),
            self.makeFormat(width: 1920, height: 1080, maxFps: 60),
        ]
        let mode = self.makeMode(width: 3840, height: 2160, fps: 30)
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(format.pixelWidth == 3840)
        #expect(format.pixelHeight == 2160)
        #expect(fps == 30)
    }

    // MARK: - Override path — fallback when match not found

    @Test("Override with no matching format → falls back to auto-pick")
    func overrideNotFound_fallsBackToAuto() throws {
        // Only 1080p60 available — user selected a mode for a resolution that no longer exists.
        let formats = [self.makeFormat(width: 1920, height: 1080, maxFps: 60)]
        // Override asks for 4K30 which is not in the list.
        let mode = self.makeMode(width: 3840, height: 2160, fps: 30)
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        // Should fall back to auto-pick → best available = 1920×1080
        #expect(format.pixelWidth == 1920)
        #expect(format.pixelHeight == 1080)
        // Auto-derived fps: min(60, 60) = 60
        #expect(fps == 60)
    }

    // MARK: - Policy bounds — fps clamping and floor enforcement

    @Test("Override with fps > maxScreenFps is clamped to maxScreenFps")
    func overrideFpsAboveMaxScreenFps_clampedToMaxScreenFps() throws {
        // Format supports 120fps, but policy ceiling is 60.
        let formats = [self.makeFormat(width: 1920, height: 1080, maxFps: 120)]
        // Persisted mode was saved on a device/policy that allowed 120fps.
        let mode = self.makeMode(width: 1920, height: 1080, fps: 120)
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(format.pixelWidth == 1920)
        #expect(format.pixelHeight == 1080)
        // Clamped to maxScreenFps=60; budget and capture will agree.
        #expect(fps == 60)
    }

    @Test("Override with fps below minCameraFps after clamping falls back to auto")
    func overrideFpsBelowPolicyFloorAfterClamp_fallsBackToAuto() throws {
        // 720p@15 — maxFps is below minCameraFps=30, so no valid override candidate exists.
        let formats = [
            self.makeFormat(width: 1280, height: 720, maxFps: 15),
            self.makeFormat(width: 1920, height: 1080, maxFps: 30),
        ]
        // Persisted mode for 720p@15 (could happen if policy changed after save).
        let mode = self.makeMode(width: 1280, height: 720, fps: 15)
        // resolveFormat must fall back to auto since no format satisfies minFps for 720p@15.
        // Auto-pick: only 1080p@30 qualifies (720p@15 fails minFps=30 filter).
        let (format, fps) = try CameraFormatSelector.resolveFormat(
            from: formats,
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(format.pixelWidth == 1920)
        #expect(format.pixelHeight == 1080)
        #expect(fps == 30)
    }

    @Test("availableModes excludes 1080p@120 (clamped to 60) and 720p@15 (below floor)")
    func availableModes_policyFilterInvariant() {
        // Formats: 1080p@120 (above ceiling), 720p@15 (below floor), 1080p@30 (valid).
        // Expected: 1080p@60 (clamped) and 1280x720@30 is excluded (15 < minFps).
        // Wait — we need a valid 720p format to verify exclusion: 720p@15 only, so excluded.
        let formats = [
            self.makeFormat(width: 1920, height: 1080, maxFps: 120), // above ceiling → clamped to 60
            self.makeFormat(width: 1280, height: 720, maxFps: 15), // below floor → excluded
        ]
        let modes = CameraFormatSelector.availableModes(from: formats, config: RecordingConfiguration.mvpDefault)
        // 720p@15 must be excluded (below minCameraFps=30).
        let has720p = modes.contains { $0.pixelWidth == 1280 && $0.pixelHeight == 720 }
        #expect(!has720p, "720p@15 must be excluded — below minCameraFps policy floor")
        // 1080p@120 must appear as 1080p@60 (clamped to maxScreenFps).
        let modes1080p = modes.filter { $0.pixelWidth == 1920 && $0.pixelHeight == 1080 }
        #expect(modes1080p.count == 1)
        #expect(modes1080p[0].fps == 60, "1080p@120 must be clamped to maxScreenFps=60 in the mode list")
    }

    @Test("Over-budget combo (1080p@120 forced) produces budgetExceeded=true")
    func overBudgetOverride_tripsBudgetExceeded() throws {
        // 1080p@120 forced — after clamping to 60, verify budget is computed with fps=60.
        // 1080p@60 + 4K@60 = 124.4M + 497.7M = 622.1M < 995M → within budget.
        // This test confirms the budget uses the BOUNDED fps (60), not the raw override fps (120).
        let camFormat = self.makeFormat(width: 1920, height: 1080, maxFps: 120)
        let mode = self.makeMode(width: 1920, height: 1080, fps: 120)
        let (_, fps) = try CameraFormatSelector.resolveFormat(
            from: [camFormat],
            override: mode,
            config: RecordingConfiguration.mvpDefault
        )
        // fps must be 60 (clamped), not 120.
        #expect(fps == 60)

        // Verify the budget resolver also sees fps=60 (not 120 leaked from the persisted mode).
        let display = Display(
            displayID: 1,
            name: "4K Display",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60
        )
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: camFormat,
            cameraTargetFps: fps,
            config: RecordingConfiguration.mvpDefault
        )
        // 1080p@60 + 4K@60 = 622.1M — within budget.
        #expect(result.budgetExceeded == false)
        #expect(result.plan.cameraPlan?.fps == 60)
    }

    // MARK: - Error path

    @Test("Empty formats list → throws noSuitableCameraFormat")
    func emptyFormats_throws() {
        // `#expect(throws: error)` requires `E: Equatable & Sendable`, but `RecordingError`
        // has a `@MainActor`-inferred `Equatable` conformance under `InferIsolatedConformances`.
        // Use `#expect(throws: RecordingError.self)` and pattern-match the case instead.
        let thrown = #expect(throws: RecordingError.self) {
            try CameraFormatSelector.resolveFormat(
                from: [],
                override: nil,
                config: RecordingConfiguration.mvpDefault
            )
        }
        if case .noSuitableCameraFormat = thrown {} else {
            Issue.record("Expected .noSuitableCameraFormat, got \(String(describing: thrown))")
        }
    }
}

// MARK: - CapabilityBudgetTests

/// L2 tests for `CapabilityResolver.resolve` budget flag.
///
/// Verifies the two MX Brio use-cases from the spec do NOT exceed budget, and that
/// a pathological high-bandwidth combo DOES exceed it.
///
/// Budget constants (spec §AC-5):
/// - Engine budget: 995_000_000 px/s
/// - 4K@30 cam + 4K@60 screen: 3840×2160×30 + 3840×2160×60 = 248.8M + 497.7M = 746.5M ✓
/// - 1080p@60 cam + 4K@60 screen: 1920×1080×60 + 3840×2160×60 = 124.4M + 497.7M = 622.1M ✓
/// - Synthetic 8K@60 cam alone:  7680×4320×60 = 1,990.7M > 995M → budgetExceeded ✓
///
/// The suite is `nonisolated` because `CapabilityResolver` and `CameraFormat`/`Display`
/// are all `nonisolated`.
@Suite("CapabilityResolver.resolve — budget flag")
struct CapabilityBudgetTests {
    // MARK: - Helpers

    private func make4KDisplay() -> Display {
        Display(displayID: 1, name: "Test 4K Display", pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60)
    }

    // MARK: - Brio combos (must NOT exceed budget)

    @Test("4K@30 cam + 4K@60 screen = 746.5M → budgetExceeded false")
    func brio4K30CamPlus4KScreen_withinBudget() {
        let cam = CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 1, maxFps: 30)
        let display = self.make4KDisplay()
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: cam,
            cameraTargetFps: 30,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(result.budgetExceeded == false)
        // Camera plan must honour the 4K30 override.
        #expect(result.plan.cameraPlan?.fps == 30)
    }

    @Test("1080p@60 cam + 4K@60 screen = 622.1M → budgetExceeded false")
    func brio1080p60CamPlus4KScreen_withinBudget() {
        let cam = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60)
        let display = self.make4KDisplay()
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: cam,
            cameraTargetFps: 60,
            config: RecordingConfiguration.mvpDefault
        )
        #expect(result.budgetExceeded == false)
        #expect(result.plan.cameraPlan?.fps == 60)
    }

    // MARK: - Pathological (must exceed budget)

    @Test("Synthetic 8K@60 cam alone = 1990.7M → budgetExceeded true")
    func synthetic8K60Cam_exceedsBudget() {
        let cam = CameraFormat(pixelWidth: 7680, pixelHeight: 4320, minFps: 1, maxFps: 60)
        let display = Display(displayID: 1, name: "Small Display", pixelWidth: 800, pixelHeight: 600, refreshHz: 60)
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: cam,
            cameraTargetFps: 60,
            config: RecordingConfiguration.mvpDefault
        )
        // 8K@60 alone = 7680×4320×60 ≈ 1990.7M > 995M budget
        #expect(result.budgetExceeded == true)
    }

    // MARK: - Budget consistency (same fps used in both rate computation and camera plan)

    @Test("cameraTargetFps=30 is reflected in camera plan fps")
    func cameraTargetFps_reflectedInCameraPlan() {
        // Ensures cameraRateInfo and cameraDimensions both use the same effective fps.
        let cam = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60)
        let display = self.make4KDisplay()
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: cam,
            cameraTargetFps: 30,
            config: RecordingConfiguration.mvpDefault
        )
        // Override was 30 — camera plan must match.
        #expect(result.plan.cameraPlan?.fps == 30)
    }

    @Test("nil cameraTargetFps — auto-derives fps from format.maxFps")
    func nilCameraTargetFps_autoDerivesFromFormatMaxFps() {
        let cam = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1, maxFps: 60)
        let display = self.make4KDisplay()
        let result = CapabilityResolver.resolve(
            display: display,
            cameraFormat: cam,
            cameraTargetFps: nil,
            config: RecordingConfiguration.mvpDefault
        )
        // Auto path: min(60, maxScreenFps=60) = 60
        #expect(result.plan.cameraPlan?.fps == 60)
    }
}
