import CoreGraphics
import CoreMedia
import os
import VideoToolbox

// MARK: - ProbeResult

/// The outcome of a `CapabilityProbe` run.
///
/// ### Case semantics
///
/// - `.ok`: Hardware HEVC encoder is available and the resolved plan fits the ≤4K60 default
///   budget. The associated `ResolvedRecordingPlan` is the concrete start profile.
///
/// - `.noHardwareEncoder`: VideoToolbox could not create a hardware HEVC session with
///   `RequireHardwareAcceleratedVideoEncoder=true`, or reported `UsingHardwareAcceleratedVideoEncoder=false`.
///   AC-6: recording must not start silently in software; the caller must reject this outcome.
///
/// - `.budgetExceeded(suggested:)`: A hardware encoder is present, but the display + camera
///   combination exceeds the engine budget (995M px/s) even after the default ≤4K60 cap.
///   The associated plan is the budget-reduced profile that `CapabilityResolver` produced;
///   the caller should present it to the user or start with it.
nonisolated enum ProbeResult {
    /// HW HEVC present and the plan fits the default budget. Associated value is the
    /// resolved start profile.
    case ok(ResolvedRecordingPlan) // swiftlint:disable:this identifier_name

    /// No hardware HEVC encoder is available on this machine (AC-6).
    case noHardwareEncoder

    /// HW HEVC present, but budget exceeded even at ≤4K60. `suggested` is the reduced plan.
    case budgetExceeded(suggested: ResolvedRecordingPlan)
}

// swiftformat:disable:next redundantEquatable
extension ProbeResult: Equatable {
    /// Manual `nonisolated` implementation.
    ///
    /// Under `InferIsolatedConformances` + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    /// synthesised `==` on enums with associated values is inferred as `@MainActor`,
    /// making it unusable from `nonisolated` contexts. Same trap as `ResolvedRecordingPlan`.
    nonisolated static func == (lhs: ProbeResult, rhs: ProbeResult) -> Bool {
        switch (lhs, rhs) {
        case let (.ok(lPlan), .ok(rPlan)):
            lPlan == rPlan

        case (.noHardwareEncoder, .noHardwareEncoder):
            true

        case let (.budgetExceeded(lPlan), .budgetExceeded(rPlan)):
            lPlan == rPlan

        default:
            false
        }
    }
}

// MARK: - CapabilityProbe

/// Impure pre-flight probe: verifies hardware HEVC availability and budget fitness.
///
/// ### Probe algorithm (spec §"CapabilityProbe и pre-flight бюджет", AC-5, AC-6)
///
/// 1. **Resolve** — call `CapabilityResolver.resolveStartProfile` to obtain the
///    budget-fitted plan (≤4K60 cap + downscale if needed).
/// 2. **HW-encoder check (AC-6)** — attempt to create a `VTCompressionSession` with
///    `RequireHardwareAcceleratedVideoEncoder = true`. If that fails, or if
///    `UsingHardwareAcceleratedVideoEncoder` is false, return `.noHardwareEncoder`.
///    The session is probed at a fixed 1920×1080; encoder existence is
///    resolution-independent and probing at a degenerate size (e.g. 2×2) risks
///    false negatives.
/// 3. **Budget classification** — check whether the ≤4K60 clamped profile itself fits
///    the budget using `EngineBudgetCap.fits(screen:camera:)`. If it fits → `.ok(plan)`.
///    If not → `.budgetExceeded(suggested: plan)`.
///
/// ### Non-isolation
/// All members are `nonisolated`. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
/// `STRICT_CONCURRENCY = complete`, `VTCompressionSessionRef` is `CM_SWIFT_NONSENDABLE` and
/// must never escape the calling function. The probe creates and invalidates the session
/// within a single stack frame.
nonisolated enum CapabilityProbe {
    // MARK: - Constants

    /// Fixed dimensions used for the hardware-encoder capability probe.
    ///
    /// Encoder existence is resolution-independent; using a standard HD resolution
    /// avoids potential false negatives at degenerate sizes (e.g. 2×2 from extreme
    /// budget-overflow paths) while keeping session setup cost negligible.
    private static let probeWidth: Int32 = 1920
    private static let probeHeight: Int32 = 1080

    /// Maximum screen width in the default ≤4K60 profile (matches `CapabilityResolver`).
    private static let maxScreenWidth4K = 3840
    /// Maximum screen height in the default ≤4K60 profile.
    private static let maxScreenHeight4K = 2160

    // MARK: - Logger

    private static let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "CapabilityProbe"
    )

    // MARK: - Entry point

    /// Runs the capability pre-flight check for the given display + optional camera.
    ///
    /// - Parameters:
    ///   - display: The selected display snapshot (from DeviceDiscovery).
    ///   - cameraFormat: The selected camera format, or `nil` when no camera is used.
    ///   - config: The recording policy (budget cap, fps limits).
    /// - Returns: A `ProbeResult` indicating hardware availability and budget fitness.
    nonisolated static func probe(
        display: Display,
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> ProbeResult {
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: cameraFormat,
            config: config
        )

        // AC-6: HW-encoder check comes first.
        // Probing at fixed 1080p avoids spurious failures on degenerate plan dimensions.
        guard self.hwEncoderAvailable(width: self.probeWidth, height: self.probeHeight) else {
            Self.logger.warning("Hardware HEVC encoder unavailable on this system")
            return .noHardwareEncoder
        }

        // Budget classification: does the default ≤4K60 clamped profile fit the budget?
        // Using fits() rather than dimension comparison correctly handles the even-floor
        // step (odd native dims shrink by 1 without any budget pressure).
        let clampedScreen = self.clampedScreenDimensions(display: display, config: config)
        let clampedCamera = self.clampedCameraSource(cameraFormat: cameraFormat, config: config)

        if config.budgetCap.fits(screen: clampedScreen, camera: clampedCamera) {
            let hasCamera = plan.cameraPlan != nil
            Self.logger.info(
                "Probe: ok — \(plan.screenWidth)×\(plan.screenHeight)@\(plan.screenFps)fps, camera: \(hasCamera)"
            )
            return .ok(plan)
        } else {
            Self.logger.warning(
                "Probe: budget exceeded — suggested \(plan.screenWidth)×\(plan.screenHeight)@\(plan.screenFps)fps"
            )
            return .budgetExceeded(suggested: plan)
        }
    }

    // MARK: - Helpers

    /// Returns `true` when a hardware HEVC encoder can be created via VideoToolbox.
    ///
    /// Creates a minimal `VTCompressionSession` with `RequireHardwareAcceleratedVideoEncoder`
    /// set to `true`, queries `UsingHardwareAcceleratedVideoEncoder`, then invalidates the
    /// session. The session is strictly local — `VTCompressionSessionRef` is `CM_SWIFT_NONSENDABLE`
    /// and never escapes this function.
    ///
    /// - Parameters:
    ///   - width: Frame width passed to `VTCompressionSessionCreate`.
    ///   - height: Frame height passed to `VTCompressionSessionCreate`.
    nonisolated private static func hwEncoderAvailable(width: Int32, height: Int32) -> Bool {
        let encoderSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true as CFBoolean,
        ] as CFDictionary

        var session: VTCompressionSession?
        // VTCompressionSessionCreate has an unsafe UnsafeMutableRawPointer parameter (refcon).
        // The `unsafe` expression is required under SWIFT_STRICT_MEMORY_SAFETY = YES.
        let createStatus = unsafe VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            Self.logger.debug("VTCompressionSessionCreate failed: OSStatus \(createStatus)")
            return false
        }

        defer { VTCompressionSessionInvalidate(session) }

        return self.queryUsingHardwareEncoder(session: session)
    }

    /// Queries `UsingHardwareAcceleratedVideoEncoder` from an existing session.
    ///
    /// Extracted to keep `hwEncoderAvailable` under the 40-line function-body-length limit.
    nonisolated private static func queryUsingHardwareEncoder(
        session: VTCompressionSession
    )
    -> Bool {
        // VTSessionCopyProperty writes a retained CFTypeRef via a void* out-pointer.
        // Under SWIFT_STRICT_MEMORY_SAFETY = YES, `&value` on a CFTypeRef? (AnyObject?)
        // would form an UnsafeMutableRawPointer to an Optional object — doubly unsafe.
        // withUnsafeMutablePointer is the correct safe bridge: it guarantees the pointer
        // is valid for the duration of the call and does not require forming raw pointers
        // to AnyObject directly.
        // VTSessionCopyProperty writes a retained CFTypeRef via a void* out-pointer.
        // Under SWIFT_STRICT_MEMORY_SAFETY = YES, `&value` on a CFTypeRef? (AnyObject?)
        // forms an UnsafeMutableRawPointer to an Optional object — doubly unsafe.
        // withUnsafeMutablePointer gives a typed pointer scoped to the call duration.
        // UnsafeMutableRawPointer(ptr) is itself unsafe and requires the `unsafe` block.
        // VTSessionCopyProperty writes a retained CFTypeRef via a void* out-pointer.
        // `withUnsafeMutablePointer` gives a typed pointer scoped to the call duration.
        // The whole block is marked `unsafe`: both `UnsafeMutableRawPointer(ptr)` (forming
        // a raw pointer from a typed one) and `VTSessionCopyProperty` (void* parameter)
        // require it under SWIFT_STRICT_MEMORY_SAFETY = YES.
        var value: CFTypeRef?
        // `unsafe` is required at three points:
        // 1. `withUnsafeMutablePointer(to: &value)` — taking a pointer to CFTypeRef? (AnyObject?)
        // 2. `UnsafeMutableRawPointer(ptr)` — forming raw pointer from typed pointer
        // 3. `VTSessionCopyProperty` — has a void* out-parameter
        // `unsafe` on the outer expression covers (1); the closure creates a new context,
        // so (2) and (3) inside the closure require a separate `unsafe` annotation.
        let copyStatus = unsafe withUnsafeMutablePointer(to: &value) { ptr in
            unsafe VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        // `as?` is rejected ("always succeeds"), `as!` is rejected ("will never produce nil").
        // Guard via CFGetTypeID, then use `unsafeDowncast` — the correct compiler-suggested
        // replacement for unsafeBitCast between two AnyObject-compatible CF types.
        guard copyStatus == noErr,
              let rawValue = value,
              CFGetTypeID(rawValue) == CFBooleanGetTypeID()
        else {
            Self.logger.debug("UsingHardwareAcceleratedVideoEncoder query failed: OSStatus \(copyStatus)")
            return false
        }
        let isHW = unsafe CFBooleanGetValue(unsafeDowncast(rawValue, to: CFBoolean.self))
        Self.logger.debug("UsingHardwareAcceleratedVideoEncoder = \(isHW)")
        return isHW
    }

    /// Reconstructs the ≤4K60 clamped screen as `SourceDimensions` for budget-fitness check.
    ///
    /// Mirrors `CapabilityResolver.clampScreen` logic: refreshHz==0 is treated as maxScreenFps.
    /// Even-floor is applied here for consistency with what the resolver produces — ensuring
    /// `fits()` uses the same pixel counts as the resolved plan's unmodified clamped baseline.
    nonisolated private static func clampedScreenDimensions(
        display: Display,
        config: RecordingConfiguration
    )
    -> SourceDimensions {
        let fps = display.refreshHz == 0.0
            ? config.maxScreenFps
            : min(Int(display.refreshHz), config.maxScreenFps)
        let width = min(display.pixelWidth, self.maxScreenWidth4K)
        let height = min(display.pixelHeight, self.maxScreenHeight4K)
        return SourceDimensions(width: width, height: height, fps: fps)
    }

    /// Returns the clamped camera `SourceDimensions`, or zero-rate when no camera.
    nonisolated private static func clampedCameraSource(
        cameraFormat: CameraFormat?,
        config: RecordingConfiguration
    )
    -> SourceDimensions {
        guard let format = cameraFormat else {
            return SourceDimensions(width: 0, height: 0, fps: 0)
        }
        let fps = min(Int(format.maxFps), config.maxScreenFps)
        return SourceDimensions(
            width: Int(format.pixelWidth),
            height: Int(format.pixelHeight),
            fps: fps
        )
    }
}
