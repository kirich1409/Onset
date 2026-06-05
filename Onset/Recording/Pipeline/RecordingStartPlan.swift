// MARK: - RecordingPipelineKind

/// Identifies one of the two output pipelines a recording session can run.
///
/// Used to tag video routing through `DualFileOutputStage` so a screen `EncodedSample`
/// is muxed into the screen file and a camera `EncodedSample` into the camera file —
/// the two CFR grids run at different fps and must never cross.
///
/// `Equatable` / `Hashable` are declared ON THE PRIMARY definition (not bare extensions) so the
/// conformances are `nonisolated` — required because `RecordingPipelineKind` is used as a
/// `Dictionary` key inside the `DualFileOutputStage` / `RecordingSession` actors. A bare
/// `extension … : Hashable` would leave the conformance `@MainActor`-isolated under
/// `InferIsolatedConformances` even with a nonisolated witness (same pattern as `RecordingState`
/// in `PipelineTypes.swift`).
nonisolated enum RecordingPipelineKind: Equatable, Hashable {
    /// The screen-capture pipeline (`ScreenSource` → encoder → screen file).
    case screen
    /// The camera-capture pipeline (`CameraSource` → encoder → camera file).
    case camera
}

extension RecordingPipelineKind {
    /// Manual `nonisolated` witness (mirrors `RecordingState`).
    nonisolated static func == (lhs: RecordingPipelineKind, rhs: RecordingPipelineKind) -> Bool {
        switch (lhs, rhs) {
        case (.screen, .screen), (.camera, .camera):
            true

        default:
            false
        }
    }
}

extension RecordingPipelineKind {
    /// Manual `nonisolated` witness (mirrors `RecordingState`).
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .screen:
            hasher.combine(0)

        case .camera:
            hasher.combine(1)
        }
    }
}

// MARK: - RecordingStartPlan

/// The concrete set of pipelines a recording session will start.
///
/// Produced by `resolveStartPlan` from `EffectivePermissions` (what is granted) AND the
/// device-presence flags (what hardware actually exists). A granted-but-absent device must
/// NOT enable its pipeline: permission alone is insufficient — the device has to be present
/// too (AC-11).
///
/// ### Audio model (MVP)
/// The microphone rides the camera's `AVCaptureSession` (`CameraSource` is the single source
/// of both camera video and mic audio). Therefore audio is only includable when the camera
/// pipeline runs: `includeAudio == true` requires `includeCamera == true`. A screen-only
/// session has no audio in MVP. The mic buffer is still fanned out to BOTH files (#33) — the
/// camera AVCaptureSession is merely the capture transport.
///
/// All members are `nonisolated` so this pure value type is usable from any isolation context.
nonisolated struct RecordingStartPlan {
    /// Whether the screen pipeline (capture → encode → screen file) runs.
    nonisolated let includeScreen: Bool

    /// Whether the camera pipeline (capture → encode → camera file) runs.
    nonisolated let includeCamera: Bool

    /// Whether a microphone audio track is muxed into the file(s).
    ///
    /// INVARIANT: `includeAudio` implies `includeCamera` — the mic is captured by the camera's
    /// `AVCaptureSession` in MVP.
    nonisolated let includeAudio: Bool

    /// The number of video pipelines that will run (1 or 2). `DualFileOutputStage` uses this as
    /// `expectedPipelines` to know when every writer has been created so the pending-audio buffer
    /// can be released.
    nonisolated var expectedPipelines: Int {
        (self.includeScreen ? 1 : 0) + (self.includeCamera ? 1 : 0)
    }
}

// swiftformat:disable:next redundantEquatable
extension RecordingStartPlan: Equatable {
    /// Manual `nonisolated` witness (mirrors `EffectivePermissions` / `DropCounters`): under
    /// `InferIsolatedConformances` a synthesised conformance would be `@MainActor` and unusable
    /// from the session actors and from `nonisolated` test contexts.
    nonisolated static func == (lhs: RecordingStartPlan, rhs: RecordingStartPlan) -> Bool {
        lhs.includeScreen == rhs.includeScreen
            && lhs.includeCamera == rhs.includeCamera
            && lhs.includeAudio == rhs.includeAudio
    }
}

// MARK: - Planner (pure)

/// Resolves which pipelines a session starts, given permissions and device presence (AC-11).
///
/// Mirrors `EffectivePermissions.compute` — a pure, side-effect-free function that the
/// `RecordingSession` actor calls at start. Two independent facts gate each pipeline:
/// 1. The permission is `authorized` (carried by `EffectivePermissions`).
/// 2. The corresponding hardware device is actually present.
///
/// Both must hold: a granted screen permission with no display attached does NOT enable the
/// screen pipeline, and likewise for camera/mic. This is the difference between "allowed" and
/// "possible" that AC-11 requires.
///
/// - Parameters:
///   - permissions: The effective (granted) permissions.
///   - screenDevicePresent: Whether a recordable display exists.
///   - cameraDevicePresent: Whether a camera device exists.
///   - micDevicePresent: Whether a microphone device exists.
/// - Returns: `.success(plan)` when at least one video pipeline can run; `.failure(.noVideoSource)`
///   when neither screen nor camera is both granted AND present (AC-11 block — the session must
///   not start).
nonisolated func resolveStartPlan(
    permissions: EffectivePermissions,
    screenDevicePresent: Bool,
    cameraDevicePresent: Bool,
    micDevicePresent: Bool
)
-> Result<RecordingStartPlan, RecordingError> {
    let includeScreen = permissions.screenAvailable && screenDevicePresent
    let includeCamera = permissions.cameraAvailable && cameraDevicePresent

    guard includeScreen || includeCamera else {
        // Neither video source is recordable — AC-11 blocks the start entirely. `noVideoSource`
        // already exists in RecordingError (do not duplicate).
        return .failure(.noVideoSource)
    }

    // Audio is gated on the camera pipeline (the mic rides the camera AVCaptureSession in MVP):
    // mic granted + present is necessary but not sufficient without a running camera pipeline.
    let includeAudio = permissions.microphoneAvailable && micDevicePresent && includeCamera

    return .success(
        RecordingStartPlan(
            includeScreen: includeScreen,
            includeCamera: includeCamera,
            includeAudio: includeAudio
        )
    )
}
