import Foundation

// MARK: - Selections

/// The user's draft recording choices that the Validator (#31) consumes to produce a
/// `ValidationOutcome`.
///
/// All fields are value types; `Selections` is `Sendable` and safe to pass across
/// actor boundaries. The Validator reads these fields against a `CapabilitySnapshot`
/// and either confirms, auto-corrects, or rejects them.
///
/// ## UI seam for #32
/// `cameraFormatOverride` is intentionally optional: `nil` means "Validator picks the
/// best available format"; a non-nil value is an explicit user selection the Settings
/// UI (#32) drives. This keeps `Selections` stable across both the no-UI (Validator
/// auto-picks) and UI-driven flows.
public struct Selections: Sendable, Equatable {
    /// `CGDirectDisplayID` of the screen to capture, or `nil` to omit screen capture.
    public var screenDisplayID: UInt32?

    /// `AVCaptureDevice.uniqueID` of the camera to capture, or `nil` to omit camera.
    public var cameraUniqueID: String?

    /// `AVCaptureDevice.uniqueID` of the microphone to capture, or `nil` to omit audio.
    public var microphoneUniqueID: String?

    /// Requested capture frame rate (fps). The Validator clamps this to each source's
    /// supported maximum and records the correction as `.frameRateClamped` when needed.
    public var targetFPS: Int

    /// Video codec for all outputs. Defaults to `.hevc` (hardware-accelerated on Apple Silicon).
    public var codec: CodecKind

    /// Output container format. Defaults to `.mov`.
    public var container: ContainerKind

    /// Directory in which output files will be created.
    ///
    /// Writability is NOT checked by the Validator (which is pure, no I/O). The
    /// recording-session coordinator (#37) verifies the path is writable when it
    /// opens the `AVAssetWriter`. Timestamped filenames and collision avoidance are
    /// deferred to that same layer.
    public var outputDirectory: URL

    /// Explicit camera format selection, or `nil` to let the Validator pick the format
    /// with the largest pixel area. Set by the Settings UI (#32).
    public var cameraFormatOverride: CameraFormatOption?

    public init(
        screenDisplayID: UInt32? = nil,
        cameraUniqueID: String? = nil,
        microphoneUniqueID: String? = nil,
        targetFPS: Int,
        codec: CodecKind = .hevc,
        container: ContainerKind = .mov,
        outputDirectory: URL,
        cameraFormatOverride: CameraFormatOption? = nil
    ) {
        self.screenDisplayID = screenDisplayID
        self.cameraUniqueID = cameraUniqueID
        self.microphoneUniqueID = microphoneUniqueID
        self.targetFPS = targetFPS
        self.codec = codec
        self.container = container
        self.outputDirectory = outputDirectory
        self.cameraFormatOverride = cameraFormatOverride
    }
}
