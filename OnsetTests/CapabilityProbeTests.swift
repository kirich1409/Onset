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

// MARK: - CapabilityProbeTests

/// Tests for `CapabilityProbe.probe(display:cameraFormat:config:)`.
///
/// These tests run on the host machine (Apple Silicon), so `hwEncoderAvailable` returns `true`.
/// `.noHardwareEncoder` is not injectable via the current static `probe()` API and is covered
/// by manual verification (L5) on a reference machine.
@Suite("CapabilityProbe.probe — live HW-encoder tests (Apple Silicon)")
struct CapabilityProbeTests {
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - .ok cases

    /// 4K60 display, no camera → no budget pressure → `.ok`.
    @Test("4K60 display without camera → .ok with the resolved plan")
    func probe_4K60_noCamera_isOk() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        guard case let .ok(plan) = result else {
            Issue.record("Expected .ok, got \(result)")
            return
        }
        #expect(plan.screenWidth == 3840)
        #expect(plan.screenHeight == 2160)
        #expect(plan.screenFps == 60)
        #expect(plan.cameraPlan == nil)
    }

    /// 1080p60 display, no camera → well within budget → `.ok`.
    @Test("1080p60 display without camera → .ok")
    func probe_1080p60_noCamera_isOk() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        if case .ok = result {} else {
            Issue.record("Expected .ok, got \(result)")
        }
    }

    /// Built-in display (refreshHz == 0.0) → treated as maxScreenFps → no budget pressure → `.ok`.
    @Test("Built-in display (refreshHz 0) without camera → .ok")
    func probe_builtIn_noCamera_isOk() {
        // Apple built-in displays report 0.0 — the probe must not treat this as 0 fps.
        let display = makeDisplay(pixelWidth: 3456, pixelHeight: 2234, refreshHz: 0.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        if case let .ok(plan) = result {
            #expect(plan.screenFps == self.config.maxScreenFps)
        } else {
            Issue.record("Expected .ok, got \(result)")
        }
    }

    /// 5K display without camera: clamps to ≤4K60 at the default profile → fits budget → `.ok`.
    @Test("5K display without camera — clamped to ≤4K60, fits budget → .ok")
    func probe_5K_noCamera_isOk() {
        // A 5K display alone is clamped to 4K60 (the default profile); 4K60 ≈ 497M px/s ≤ 995M.
        // Downscaling the native 5K to 4K is the NORMAL profile, not a budget overflow.
        let display = makeDisplay(pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        if case let .ok(plan) = result {
            // Clamped to ≤4K60.
            #expect(plan.screenWidth <= 3840)
            #expect(plan.screenHeight <= 2160)
        } else {
            Issue.record("Expected .ok, got \(result)")
        }
    }

    /// Odd-dimension display without camera → even-floored result → no budget pressure → `.ok`.
    ///
    /// Regression: the original dimension-comparison approach would fire `.budgetExceeded`
    /// here because `1918 < 1919`. The `fits()`-based approach correctly returns `.ok`.
    @Test("Odd-width display without camera — even-floor only, no budget pressure → .ok")
    func probe_oddWidth_noCamera_isOk() {
        let display = makeDisplay(pixelWidth: 1919, pixelHeight: 1080, refreshHz: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        )

        if case .ok = result {} else {
            Issue.record("Expected .ok (even-floor is not a budget downscale), got \(result)")
        }
    }

    /// 4K60 + 1080p30 camera: 497M + 62M ≈ 559M ≤ 995M → `.ok`.
    @Test("4K60 display + 1080p30 camera — combined rate within budget → .ok")
    func probe_4K60_1080p30_isOk() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let camera = makeCamera(pixelWidth: 1920, pixelHeight: 1080, maxFps: 30.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: camera,
            config: self.config
        )

        if case let .ok(plan) = result {
            guard let cam = plan.cameraPlan else {
                Issue.record("Expected a camera plan")
                return
            }
            #expect(cam.width == 1920)
            #expect(cam.height == 1080)
            #expect(cam.fps == 30)
        } else {
            Issue.record("Expected .ok, got \(result)")
        }
    }

    // MARK: - .budgetExceeded cases

    /// 4K60 + large 4K@60 camera: clamped combined rate 497M + 530M ≈ 1027M > 995M → `.budgetExceeded`.
    ///
    /// This is the same math as the CapabilityResolverTests fps-fallback case.
    @Test("4K60 display + large 4K@60 camera — clamped baseline > 995M → .budgetExceeded")
    func probe_4K60_largeCam60_isBudgetExceeded() {
        // Camera: 4096×2160@60 → 530_841_600 px/s
        // Screen clamped: 3840×2160@60 → 497_664_000 px/s
        // Combined: 1_028_505_600 > 995_000_000
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let bigCamera = makeCamera(pixelWidth: 4096, pixelHeight: 2160, maxFps: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: bigCamera,
            config: self.config
        )

        guard case let .budgetExceeded(suggested) = result else {
            Issue.record("Expected .budgetExceeded, got \(result)")
            return
        }
        // The suggested plan must fit within budget.
        #expect(suggested.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
        // Dimensions must be even.
        #expect(suggested.screenWidth.isMultiple(of: 2))
        #expect(suggested.screenHeight.isMultiple(of: 2))
    }

    // MARK: - ProbeResult equality

    //
    // `ProbeResult: Equatable` conformance is manually `nonisolated` (see CapabilityProbe.swift).
    // `#expect(a == b)` where a/b are `ProbeResult` routes through the Equatable protocol
    // witness table. Under `InferIsolatedConformances` the witness is `@MainActor`-inferred
    // even when the `==` implementation is `nonisolated`. Running the equality tests on
    // `@MainActor` is the conformance-safe path here.

    @Test("ProbeResult.ok equality")
    @MainActor
    func probeResult_ok_equality() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        let lhs = ProbeResult.ok(plan)
        let rhs = ProbeResult.ok(plan)
        #expect(lhs == rhs)
    }

    @Test("ProbeResult.noHardwareEncoder equality with .budgetExceeded")
    @MainActor
    func probeResult_noHardwareEncoder_notEqualBudgetExceeded() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        // .noHardwareEncoder is distinct from all other cases
        #expect(ProbeResult.noHardwareEncoder != ProbeResult.ok(plan))
        #expect(ProbeResult.noHardwareEncoder != ProbeResult.budgetExceeded(suggested: plan))
    }

    @Test("ProbeResult inequality across cases")
    @MainActor
    func probeResult_crossCase_notEqual() {
        let display = makeDisplay(pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60.0)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: nil,
            config: self.config
        )
        #expect(ProbeResult.ok(plan) != ProbeResult.noHardwareEncoder)
        #expect(ProbeResult.noHardwareEncoder != ProbeResult.budgetExceeded(suggested: plan))
    }
}

// swiftlint:enable no_magic_numbers
