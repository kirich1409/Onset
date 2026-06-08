// MARK: - DeviceSelectionOutcome

/// The result of resolving a persisted device selection against the current available list.
///
/// Produced by `DeviceSelectionResolver.resolve(saved:availableIDs:)` and consumed by
/// `loadCamerasAndMicrophones()` to set the view-model's selection state without
/// implementing the logic inline.
///
/// ### Invariant
/// A `.disconnected` outcome must NEVER coexist with an auto-selected fallback for the
/// same device. Callers gate `selectFirstCameraIfNeeded` behind `.noSavedSelection` only.
nonisolated enum DeviceSelectionOutcome: Equatable {
    /// The saved device is present — restore its `uniqueID` and clear any notice.
    case restore(uniqueID: String)

    /// The saved device is absent — surface the saved name for the disconnected-device
    /// notice and do NOT auto-pick a replacement.
    case disconnected(savedName: String)

    /// No saved selection exists — caller applies its own default (e.g. first-camera
    /// auto-select or leave mic unselected).
    case noSavedSelection
}

// MARK: - CameraOutcome

/// The result of resolving a persisted camera selection, extending `DeviceSelectionOutcome`
/// with a `.disabled` case for when the user has explicitly turned the camera off.
///
/// Produced by `DeviceSelectionResolver.resolveCamera(saved:availableIDs:)` only.
/// Microphone resolution uses the plain `DeviceSelectionOutcome` — mic has no disable toggle.
nonisolated enum CameraOutcome: Equatable {
    /// The user explicitly disabled the camera — restore `cameraEnabled = false`, no auto-select.
    case disabled

    /// The saved device is present — restore its `uniqueID` and enable the camera.
    ///
    /// `mode` carries the persisted `CameraMode` selection, or `nil` for Auto mode.
    case restore(uniqueID: String, mode: CameraMode?)

    /// The saved device is absent — surface the saved name for the disconnected-device
    /// notice and do NOT auto-pick a replacement.
    case disconnected(savedName: String)

    /// No saved value — first launch or explicitly cleared; caller applies the default
    /// (first-camera auto-select with `cameraEnabled = true`).
    case noSavedSelection
}

// MARK: - DeviceSelectionResolver

/// Pure resolver for persisted device selections.
///
/// Converts persisted selection values into explicit outcomes without accessing `UserDefaults`,
/// `MainActor` state, or any hardware API.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests without an actor context.
nonisolated enum DeviceSelectionResolver {
    /// Resolves a persisted microphone selection against the current device list.
    ///
    /// - Parameters:
    ///   - saved: The persisted `DeviceSelectionRecord`, or `nil` when no record exists.
    ///   - availableIDs: The `uniqueID`s of all currently available devices for this role.
    /// - Returns:
    ///   - `.restore(uniqueID:)` when the saved device is present in `availableIDs`.
    ///   - `.disconnected(savedName:)` when a record exists but its `uniqueID` is absent.
    ///   - `.noSavedSelection` when `saved` is `nil` (first launch or explicitly cleared).
    nonisolated static func resolve(
        saved: DeviceSelectionRecord?,
        availableIDs: [String]
    )
    -> DeviceSelectionOutcome {
        guard let record = saved else {
            return .noSavedSelection
        }
        if availableIDs.contains(record.uniqueID) {
            return .restore(uniqueID: record.uniqueID)
        } else {
            return .disconnected(savedName: record.localizedName)
        }
    }

    /// Resolves a persisted camera selection against the current device list.
    ///
    /// Handles the camera-specific `.disabled` case in addition to the standard
    /// restore/disconnected/noSavedSelection outcomes.
    ///
    /// - Parameters:
    ///   - saved: The persisted `PersistedCameraSelection`, or `nil` when no record exists.
    ///   - availableIDs: The `uniqueID`s of all currently available camera devices.
    /// - Returns:
    ///   - `.disabled` when the user had explicitly disabled the camera.
    ///   - `.restore(uniqueID:)` when the saved device is present in `availableIDs`.
    ///   - `.disconnected(savedName:)` when a record exists but its `uniqueID` is absent.
    ///   - `.noSavedSelection` when `saved` is `nil` (first launch or explicitly cleared).
    nonisolated static func resolveCamera(
        saved: PersistedCameraSelection?,
        availableIDs: [String]
    )
    -> CameraOutcome {
        switch saved {
        case .none:
            .noSavedSelection

        case .disabled:
            .disabled

        case let .enabled(record, mode: mode):
            if availableIDs.contains(record.uniqueID) {
                .restore(uniqueID: record.uniqueID, mode: mode)
            } else {
                .disconnected(savedName: record.localizedName)
            }
        }
    }
}
