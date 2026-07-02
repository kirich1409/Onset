@testable import Onset
import Testing

// MARK: - AppSettingsTests

/// Swift Testing suite for `AppSettings` (T-3).
///
/// Covers the two behaviors the shared model is responsible for: loading both settings from the
/// injected `SettingsPersisting` at init, and writing each mutation through to the store
/// synchronously via `didSet` (assertions run immediately after the assignment — no `await` —
/// proving the write is synchronous). All cases use an `InMemorySettingsStore` double.
@Suite("AppSettings")
@MainActor
struct AppSettingsTests {
    @Test("Loads every setting from the store at init")
    func loadsFromStoreAtInit() {
        let store = InMemorySettingsStore(showMenuBarTimer: false, cameraMirror: true, cameraStabilization: true)
        let settings = AppSettings(store: store)
        #expect(settings.showMenuBarTimer == false)
        #expect(settings.cameraMirror == true)
        #expect(settings.cameraStabilization == true)
    }

    @Test("Resolves per-setting defaults when the store holds them")
    func loadsDefaultsAtInit() {
        let settings = AppSettings(store: InMemorySettingsStore())
        #expect(settings.showMenuBarTimer == SettingsDefaults.showMenuBarTimer)
        #expect(settings.cameraMirror == SettingsDefaults.cameraMirror)
        // #297 AC-5: camera stabilization is opt-in — the default MUST be OFF.
        #expect(settings.cameraStabilization == false)
    }

    @Test("Mutating showMenuBarTimer writes through to the store synchronously")
    func showMenuBarTimerWritesThrough() {
        let store = InMemorySettingsStore(showMenuBarTimer: true)
        let settings = AppSettings(store: store)
        settings.showMenuBarTimer = false
        #expect(store.loadShowMenuBarTimer() == false)
    }

    @Test("Mutating cameraMirror writes through to the store synchronously")
    func cameraMirrorWritesThrough() {
        let store = InMemorySettingsStore(cameraMirror: false)
        let settings = AppSettings(store: store)
        settings.cameraMirror = true
        #expect(store.loadCameraMirror() == true)
    }

    @Test("Mutating cameraStabilization writes through to the store synchronously")
    func cameraStabilizationWritesThrough() {
        let store = InMemorySettingsStore(cameraStabilization: false)
        let settings = AppSettings(store: store)
        settings.cameraStabilization = true
        #expect(store.loadCameraStabilization() == true)
    }
}
