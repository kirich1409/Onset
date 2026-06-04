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
    Display(displayID: displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: refreshHz)
}

private func makeCamera(pixelWidth: Int32, pixelHeight: Int32, maxFps: Double) -> CameraFormat {
    CameraFormat(pixelWidth: pixelWidth, pixelHeight: pixelHeight, minFps: 1.0, maxFps: maxFps)
}

// MARK: - CapabilityProbeTests

// swiftlint:disable type_body_length
/// Tests for `CapabilityProbe.probe(display:cameraFormat:config:)`.
///
/// These tests run on the host machine (Apple Silicon), so `hwEncoderAvailable` returns `true`.
/// The `.noHardwareEncoder` path is covered by the injectable `hwCheck` seam tests below.
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

        switch result {
        case let .ok(plan):
            #expect(plan.screenWidth == 3840)
            #expect(plan.screenHeight == 2160)
            #expect(plan.screenFps == 60)
            #expect(plan.cameraPlan == nil)

        case .noHardwareEncoder:
            // HW HEVC absent on this runner — skip budget assertions.
            return

        case .budgetExceeded:
            Issue.record("Expected .ok or .noHardwareEncoder, got \(result)")
        }
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

        switch result {
        case .ok:
            break

        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip.

        case .budgetExceeded:
            Issue.record("Expected .ok or .noHardwareEncoder, got \(result)")
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

        switch result {
        case let .ok(plan):
            #expect(plan.screenFps == self.config.maxScreenFps)

        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip.

        case .budgetExceeded:
            Issue.record("Expected .ok or .noHardwareEncoder, got \(result)")
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

        switch result {
        case let .ok(plan):
            // Clamped to ≤4K60.
            #expect(plan.screenWidth <= 3840)
            #expect(plan.screenHeight <= 2160)

        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip.

        case .budgetExceeded:
            Issue.record("Expected .ok or .noHardwareEncoder, got \(result)")
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

        switch result {
        case .ok:
            break

        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip.

        case .budgetExceeded:
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

        switch result {
        case let .ok(plan):
            guard let cam = plan.cameraPlan else {
                Issue.record("Expected a camera plan")
                return
            }
            #expect(cam.width == 1920)
            #expect(cam.height == 1080)
            #expect(cam.fps == 30)

        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip.

        case .budgetExceeded:
            Issue.record("Expected .ok or .noHardwareEncoder, got \(result)")
        }
    }

    // MARK: - .budgetExceeded cases

    /// 4K60 + large 4K@60 camera: clamped combined rate 497M + 530M ≈ 1027M > 995M → `.budgetExceeded`.
    ///
    /// Per spec AC-5 / §"CapabilityProbe и pre-flight бюджет", the suggested plan uses
    /// resolution downscale (PRIMARY lever) at the capped fps=60, not fps reduction.
    @Test("4K60 display + large 4K@60 camera — clamped baseline > 995M → .budgetExceeded")
    func probe_4K60_largeCam60_isBudgetExceeded() {
        // Camera: 4096×2160@60 → 530_841_600 px/s
        // Screen clamped: 3840×2160@60 → 497_664_000 px/s
        // Combined: 1_028_505_600 > 995_000_000
        // Suggested plan (downscale-first at fps=60): 3708×2086@60 + camera ≈ 994M ≤ 995M.
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)
        let bigCamera = makeCamera(pixelWidth: 4096, pixelHeight: 2160, maxFps: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: bigCamera,
            config: self.config
        )

        switch result {
        case .noHardwareEncoder:
            return // HW HEVC absent on this runner — skip budget assertions.

        case let .budgetExceeded(suggested):
            // The suggested plan must fit within budget.
            #expect(suggested.combinedPixelsPerSecond <= self.config.budgetCap.maxPixelsPerSecond)
            // Dimensions must be even.
            #expect(suggested.screenWidth.isMultiple(of: 2))
            #expect(suggested.screenHeight.isMultiple(of: 2))
            // PRIMARY lever: resolution is downscaled, fps stays at the capped value (60).
            #expect(suggested.screenFps == 60)
            #expect(suggested.screenWidth < 3840)
            // Exact solver output: 3708×2086@60.
            #expect(suggested.screenWidth == 3708)
            #expect(suggested.screenHeight == 2086)
            // Aspect ratio of suggested screen ≈ 16:9.
            let aspect = Double(suggested.screenWidth) / Double(suggested.screenHeight)
            #expect(abs(aspect - 16.0 / 9.0) < 0.05)

        case .ok:
            Issue.record("Expected .budgetExceeded, got \(result)")
        }
    }

    // MARK: - AC-6: .noHardwareEncoder path (injectable seam)

    /// Forces `.noHardwareEncoder` via the injectable `hwCheck` seam.
    ///
    /// Tests the path without requiring a machine that lacks a HW HEVC encoder.
    @Test("hwCheck returning false → .noHardwareEncoder (AC-6 injectable seam)")
    func probe_hwCheckFalse_isNoHardwareEncoder() {
        let display = makeDisplay(pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60.0)

        let result = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        ) { _, _ in false }

        #expect(result == .noHardwareEncoder)
    }

    /// Verifies the seam passes the correct probe dimensions to `hwCheck`.
    @Test("hwCheck receives the fixed probe dimensions (1920×1080)")
    func probe_hwCheckReceivesProbe1080p() {
        let display = makeDisplay(pixelWidth: 4096, pixelHeight: 2160, refreshHz: 60.0)
        var capturedWidth = 0
        var capturedHeight = 0

        _ = CapabilityProbe.probe(
            display: display,
            cameraFormat: nil,
            config: self.config
        ) { probeWidth, probeHeight in
            capturedWidth = probeWidth
            capturedHeight = probeHeight
            return false // force early return; result not relevant here
        }

        #expect(capturedWidth == 1920)
        #expect(capturedHeight == 1080)
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

// swiftlint:enable type_body_length
