import CoreGraphics

// MARK: - ResolvedCameraPlan

/// The concrete camera parameters the session starts with.
///
/// This is the resolved (capped + budget-fitted) camera plan — the format is
/// pre-selected by the caller (U3.1 / #29). Only the fps used in the pipeline
/// is included here; width/height are carried from the originating `CameraFormat`.
nonisolated struct ResolvedCameraPlan {
    /// Frame width in pixels (Int projection of `CameraFormat.pixelWidth`).
    nonisolated let width: Int
    /// Frame height in pixels (Int projection of `CameraFormat.pixelHeight`).
    nonisolated let height: Int
    /// Target frame rate for the session. `Int(CameraFormat.maxFps)`,
    /// not exceeding `RecordingConfiguration.maxScreenFps`.
    nonisolated let fps: Int

    init(width: Int, height: Int, fps: Int) {
        // HEVC invariant: camera dimensions must be even and positive.
        // swiftlint:disable no_magic_numbers
        precondition(width > 0 && width.isMultiple(of: 2), "width must be even+positive, got \(width)")
        precondition(height > 0 && height.isMultiple(of: 2), "height must be even+positive, got \(height)")
        // swiftlint:enable no_magic_numbers
        self.width = width
        self.height = height
        self.fps = fps
    }
}

extension ResolvedCameraPlan: Equatable {}

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
            return lhsCam.width == rhsCam.width
                && lhsCam.height == rhsCam.height
                && lhsCam.fps == rhsCam.fps
        }
    }
}
