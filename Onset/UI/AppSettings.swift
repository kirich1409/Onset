import Foundation

// MARK: - AppSettings

/// Shared, in-memory source of truth for the user-configurable app settings.
///
/// One `@Observable` instance is owned at the composition root (`OnsetApp`) and injected into
/// every consumer (the Settings scene, `MenuBarLabel`, and `MainViewModel`). SwiftUI observation
/// propagates through this shared reference — NOT through `UserDefaults` writes — so a toggle in
/// the Settings window re-renders the live menu-bar label and camera preview immediately.
///
/// Each stored property loads from the injected `SettingsPersisting` at init and **writes through
/// synchronously** on mutation via `didSet`: the assignment both persists the value and triggers
/// `@Observable` invalidation. Consumers read the value from here, never from the store directly,
/// so there is a single in-memory read path.
@Observable
@MainActor
final class AppSettings {
    /// Per-key persistence backend. `@ObservationIgnored` because the store is an implementation
    /// detail — observation is driven by the `Bool` properties, not by the store reference.
    @ObservationIgnored
    private let store: any SettingsPersisting

    /// Whether the menu-bar label shows the elapsed-time string while recording.
    ///
    /// Mutating this persists the new value synchronously and invalidates observers, so
    /// `MenuBarLabel` shows/hides the timer live. Loaded from the store at init (default `true`,
    /// preserving the pre-Settings always-on timer).
    var showMenuBarTimer: Bool {
        didSet { self.store.saveShowMenuBarTimer(self.showMenuBarTimer) }
    }

    /// Whether the camera image is horizontally mirrored.
    ///
    /// The live preview reflects a change immediately (a cheap preview-layer transform); a
    /// recording honors the value captured at its next start (the one-shot pipeline cannot
    /// reconfigure mid-record). Mutating this persists synchronously and invalidates observers.
    /// Loaded from the store at init (default `false`, raw sensor orientation).
    var cameraMirror: Bool {
        didSet { self.store.saveCameraMirror(self.cameraMirror) }
    }

    /// Whether camera stabilization is enabled for recordings (#297).
    ///
    /// `.nextRecordingStart` policy: the value is read fresh at record start and fixed for the
    /// session (the session-fixed crop geometry and buffer pools cannot change mid-record).
    /// Affects ONLY the recorded file — the live preview runs outside the stabilization stage
    /// by design. Mutating persists synchronously and invalidates observers. Loaded from the
    /// store at init (default `false`, opt-in).
    var cameraStabilization: Bool {
        didSet { self.store.saveCameraStabilization(self.cameraStabilization) }
    }

    /// Creates the model, loading both settings from `store`.
    ///
    /// - Parameter store: The persistence backend. Production callers use the default
    ///   `UserDefaultsSettingsStore`; the root owner (`OnsetApp`) injects an
    ///   `InMemorySettingsStore` under XCTest, and tests inject one directly (see
    ///   `OnsetTests/CLAUDE.md`). `didSet` does not fire during initialization, so these
    ///   initial loads do not trigger a redundant write-back.
    init(store: any SettingsPersisting = UserDefaultsSettingsStore()) {
        self.store = store
        self.showMenuBarTimer = store.loadShowMenuBarTimer()
        self.cameraMirror = store.loadCameraMirror()
        self.cameraStabilization = store.loadCameraStabilization()
    }
}
