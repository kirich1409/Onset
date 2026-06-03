/// The recording modes available given the three current permission statuses.
///
/// Encodes the graceful-degradation rules from AC-7 and AC-11:
/// - At least one video source (screen OR camera) is required to record.
/// - Audio is optional; its absence disables the audio track only.
/// - No video source → recording is blocked entirely.
///
/// All members are `nonisolated` so this pure value type can be used from any
/// isolation context without actor hopping (required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
struct EffectivePermissions: Equatable {
    /// Whether recording with screen capture is available.
    nonisolated let screenAvailable: Bool
    /// Whether recording with camera video is available.
    nonisolated let cameraAvailable: Bool
    /// Whether the microphone audio track is available.
    nonisolated let microphoneAvailable: Bool

    // MARK: - Derived availability (pure, no side effects)

    /// Recording is possible when at least one video source is available.
    nonisolated var canRecord: Bool {
        self.screenAvailable || self.cameraAvailable
    }

    /// Screen + camera + audio — the full recording mode.
    nonisolated var fullModeAvailable: Bool {
        self.screenAvailable && self.cameraAvailable && self.microphoneAvailable
    }

    /// Screen-only mode (camera not granted; audio optional).
    nonisolated var screenOnlyAvailable: Bool {
        self.screenAvailable && !self.cameraAvailable
    }

    /// Camera-only mode ("Продолжить без экрана" from AC-7).
    ///
    /// Available when screen is denied or not determined but camera is granted.
    nonisolated var cameraOnlyAvailable: Bool {
        !self.screenAvailable && self.cameraAvailable
    }

    /// Recording without audio ("Записать без звука" from AC-7).
    ///
    /// True when at least one video source is available but microphone is not granted.
    nonisolated var videoWithoutAudioAvailable: Bool {
        self.canRecord && !self.microphoneAvailable
    }

    // MARK: - Factory

    /// Computes effective permissions from the three individual statuses.
    ///
    /// - Parameters:
    ///   - screen: Screen recording permission status.
    ///   - camera: Camera permission status.
    ///   - microphone: Microphone permission status.
    nonisolated static func compute(
        screen: PermissionStatus,
        camera: PermissionStatus,
        microphone: PermissionStatus
    )
    -> Self {
        Self(
            screenAvailable: screen == .authorized,
            cameraAvailable: camera == .authorized,
            microphoneAvailable: microphone == .authorized
        )
    }
}

// MARK: - Authorized count

extension EffectivePermissions {
    /// The number of authorized permissions out of three (the "N из 3" progress value).
    ///
    /// Used by the onboarding progress indicator and `PermissionsService.progress`.
    nonisolated var authorizedCount: Int {
        (self.screenAvailable ? 1 : 0) + (self.cameraAvailable ? 1 : 0) + (self.microphoneAvailable ? 1 : 0)
    }
}
