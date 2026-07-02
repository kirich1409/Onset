import CoreGraphics

// MARK: - ResolvedCameraPlan

/// The concrete camera parameters the session starts with.
///
/// This is the resolved (capped + budget-fitted) camera plan — the format is
/// pre-selected by the caller (U3.1 / #29). Only the fps used in the pipeline
/// is included here; width/height are carried from the originating `CameraFormat`.
nonisolated struct ResolvedCameraPlan {
    // MARK: - StabilizationPlan

    /// Session-fixed stabilization geometry (#297), resolved by `CapabilityResolver` from the
    /// planned camera dimensions when the user toggle is ON. `nil` on `stabilization` = OFF.
    ///
    /// Only the *plan-time* geometry lives here — the runtime estimation scale (`estScale`) is
    /// deliberately absent: it is chosen by the stage's warm-up from the MEASURED frame cadence
    /// (the planned fps lies — the Brio announces 60 and delivers 20–25), never pre-flight.
    nonisolated struct StabilizationPlan {
        /// Session-fixed crop rectangle in planned camera-pixel coordinates: exactly 16:9 with
        /// even dimensions. 1080p → `(16, 9, 1888, 1062)`; 4K → `(32, 18, 3776, 2124)`.
        /// `VideoToolbox` requires immutable output dimensions, so the crop never changes
        /// mid-session; the per-frame translation correction is clamped to the crop margins.
        nonisolated let cropRect: CGRect

        /// Isotropic scale factor restoring the cropped image to the planned output dimensions
        /// (`planWidth / cropRect.width`, ≈1.016949 for the canonical margins). Keeps the output
        /// file at the PLANNED resolution (scale-back, not "smaller output") per AC-7.
        nonisolated let scaleBack: Double

        /// - Parameters:
        ///   - cropRect: Even-dimensioned 16:9 crop within the planned frame.
        ///   - scaleBack: Isotropic factor back to planned dimensions. Must be > 1.
        init(cropRect: CGRect, scaleBack: Double) {
            precondition(
                cropRect.width > 0 && cropRect.height > 0,
                "cropRect must be non-empty, got \(String(describing: cropRect))"
            )
            precondition(scaleBack > 1.0, "scaleBack must exceed 1, got \(scaleBack)")
            self.cropRect = cropRect
            self.scaleBack = scaleBack
        }
    }

    /// Frame width in pixels (Int projection of `CameraFormat.pixelWidth`).
    nonisolated let width: Int
    /// Frame height in pixels (Int projection of `CameraFormat.pixelHeight`).
    nonisolated let height: Int
    /// Target frame rate for the session. `Int(CameraFormat.maxFps)`,
    /// not exceeding `RecordingConfiguration.maxScreenFps`.
    nonisolated let fps: Int
    /// Stabilization geometry, or `nil` when the stabilization toggle is OFF (#297).
    nonisolated let stabilization: StabilizationPlan?

    init(width: Int, height: Int, fps: Int, stabilization: StabilizationPlan? = nil) {
        // HEVC invariant: camera dimensions must be even and positive.
        // swiftlint:disable no_magic_numbers
        precondition(width > 0 && width.isMultiple(of: 2), "width must be even+positive, got \(width)")
        precondition(height > 0 && height.isMultiple(of: 2), "height must be even+positive, got \(height)")
        // swiftlint:enable no_magic_numbers
        self.width = width
        self.height = height
        self.fps = fps
        self.stabilization = stabilization
    }
}

extension ResolvedCameraPlan: Equatable {}

// swiftformat:disable:next redundantEquatable
extension ResolvedCameraPlan.StabilizationPlan: Equatable {
    /// Manual nonisolated `==` (#297).
    ///
    /// Declared manually — not synthesised — so `Optional<StabilizationPlan>.==` and the
    /// containing plans' manual `==` implementations can compare the field from `nonisolated`
    /// contexts without tripping the `InferIsolatedConformances` `@MainActor` witness trap
    /// (same rationale as `ResolvedRecordingPlan.==` below).
    nonisolated static func == (
        lhs: ResolvedCameraPlan.StabilizationPlan,
        rhs: ResolvedCameraPlan.StabilizationPlan
    )
    -> Bool {
        lhs.cropRect == rhs.cropRect && lhs.scaleBack == rhs.scaleBack
    }
}

// MARK: - ResolvedRecordingPlan

/// The concrete start profile produced by `CapabilityResolver`.
///
/// This is the **Probe→Screen seam contract**: `ScreenSource.start(...)` (#28)
/// consumes this to build its `SCStreamConfiguration`. It is a start-only
/// snapshot — runtime degradation (#35 DropMonitor) is a separate concern.
///
/// ### Invariants guaranteed by `CapabilityResolver.resolveStartProfile`:
/// - `screenWidth` and `screenHeight` are always even (HEVC constraint).
/// - `screenFps` ≤ `RecordingConfiguration.maxScreenFps`.
/// - Combined pixel-rate ≤ `RecordingConfiguration.budgetCap.maxPixelsPerSecond`
///   (for realistically sized sources).
nonisolated struct ResolvedRecordingPlan {
    // MARK: - Screen

    /// Core Graphics identifier of the display being captured.
    nonisolated let displayID: CGDirectDisplayID

    /// Resolved screen frame width in pixels. Always even — HEVC requires even dimensions.
    nonisolated let screenWidth: Int

    /// Resolved screen frame height in pixels. Always even.
    nonisolated let screenHeight: Int

    /// Resolved screen frame rate (fps). ≤ `RecordingConfiguration.maxScreenFps`.
    nonisolated let screenFps: Int

    // MARK: - Camera (optional)

    /// Resolved camera plan, or `nil` when no camera is selected for this session.
    nonisolated let cameraPlan: ResolvedCameraPlan?

    init(
        displayID: CGDirectDisplayID,
        screenWidth: Int,
        screenHeight: Int,
        screenFps: Int,
        cameraPlan: ResolvedCameraPlan?
    ) {
        // HEVC invariants: screen dimensions must be even and positive; fps must be positive.
        // swiftlint:disable no_magic_numbers
        precondition(
            screenWidth > 0 && screenWidth.isMultiple(of: 2),
            "screenWidth must be even+positive, got \(screenWidth)"
        )
        precondition(
            screenHeight > 0 && screenHeight.isMultiple(of: 2),
            "screenHeight must be even+positive, got \(screenHeight)"
        )
        precondition(screenFps > 0, "screenFps must be > 0, got \(screenFps)")
        // swiftlint:enable no_magic_numbers
        self.displayID = displayID
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenFps = screenFps
        self.cameraPlan = cameraPlan
    }

    // MARK: - Diagnostic

    /// Combined pixel-rate of screen + camera (pixels/second).
    ///
    /// Exposed for diagnostics and test assertions.
    /// Equals `screenWidth × screenHeight × screenFps + cameraPlan?.width × height × fps`.
    nonisolated var combinedPixelsPerSecond: Int {
        let screenRate = self.screenWidth * self.screenHeight * self.screenFps
        let cameraRate = self.cameraPlan.map { $0.width * $0.height * $0.fps } ?? 0
        return screenRate + cameraRate
    }
}

// swiftformat:disable:next redundantEquatable
extension ResolvedRecordingPlan: Equatable {
    /// Manual nonisolated == is required here.
    ///
    /// `Optional<ResolvedCameraPlan>` compares via `Optional.==`'s protocol witness.
    /// Under `InferIsolatedConformances` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// the synthesised `ResolvedCameraPlan: Equatable` conformance is inferred as
    /// `@MainActor`, which makes `Optional<ResolvedCameraPlan>.==` unavailable from a
    /// `nonisolated` context (same trap CameraDevice hits — see CaptureDeviceModels.swift).
    /// Writing a manual nonisolated `==` here routes around the witness table.
    nonisolated static func == (lhs: ResolvedRecordingPlan, rhs: ResolvedRecordingPlan) -> Bool {
        guard lhs.displayID == rhs.displayID,
              lhs.screenWidth == rhs.screenWidth,
              lhs.screenHeight == rhs.screenHeight,
              lhs.screenFps == rhs.screenFps
        else { return false }

        switch (lhs.cameraPlan, rhs.cameraPlan) {
        case (.none, .none):
            return true

        case (.some, .none), (.none, .some):
            return false

        case let (.some(lhsCam), .some(rhsCam)):
            // Field-by-field compare (#297 trap): a new ResolvedCameraPlan field MUST be added
            // here by hand — the compiler cannot flag an incomplete manual ==.
            return lhsCam.width == rhsCam.width
                && lhsCam.height == rhsCam.height
                && lhsCam.fps == rhsCam.fps
                && Self.stabilizationEqual(lhsCam.stabilization, rhsCam.stabilization)
        }
    }

    /// Compares the optional stabilization plans via the manual nonisolated witness, avoiding
    /// `Optional.==`'s protocol witness (which would bind the `@MainActor`-inferred conformance).
    nonisolated private static func stabilizationEqual(
        _ lhs: ResolvedCameraPlan.StabilizationPlan?,
        _ rhs: ResolvedCameraPlan.StabilizationPlan?
    )
    -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true

        case (.some, .none), (.none, .some):
            false

        case let (.some(lhsPlan), .some(rhsPlan)):
            lhsPlan == rhsPlan
        }
    }
}
