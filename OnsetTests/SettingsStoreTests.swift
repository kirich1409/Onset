import Foundation
@testable import Onset
import Testing

// MARK: - SettingsStoreTests

/// L2 tests for `UserDefaultsSettingsStore` per-key `Bool` persistence and the
/// `InMemorySettingsStore` double.
///
/// Covers:
/// 1. Per-key round-trip: save then load returns the saved value (both keys).
/// 2. Absent key resolves to ITS own default (true for timer, false for mirror).
/// 3. Isolated corrupt-heal: corrupting one key resolves it to its default while the
///    other key stays intact.
/// 4. Saving one key does not affect the other's default.
/// 5. `InMemorySettingsStore` round-trips both keys.
///
/// Every `UserDefaults` test goes through `withScopedDefaults` — no `.plist` file is written.
/// The suite is `@MainActor` because `UserDefaultsSettingsStore` methods are
/// `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("SettingsStore — per-key Bool persistence")
@MainActor
struct SettingsStoreTests {
    // MARK: - Helpers

    private func makeStore(defaults: InMemoryUserDefaults) -> UserDefaultsSettingsStore {
        UserDefaultsSettingsStore(defaults: defaults)
    }

    // MARK: - Test 1: Per-key round-trip (P0)

    @Test("showMenuBarTimer save then load returns the saved value")
    func showMenuBarTimer_saveThenLoad_returnsSaved() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            // Save the non-default value to prove the stored value (not the default) is returned.
            store.saveShowMenuBarTimer(false)
            #expect(store.loadShowMenuBarTimer() == false)
        }
    }

    @Test("cameraMirror save then load returns the saved value")
    func cameraMirror_saveThenLoad_returnsSaved() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveCameraMirror(true)
            #expect(store.loadCameraMirror() == true)
        }
    }

    // MARK: - Test 2: Absent key resolves to its own default (P1)

    @Test("absent showMenuBarTimer resolves to its default (true)")
    func absentShowMenuBarTimer_resolvesToDefault() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            #expect(store.loadShowMenuBarTimer() == SettingsDefaults.showMenuBarTimer)
            #expect(store.loadShowMenuBarTimer() == true)
        }
    }

    @Test("absent cameraMirror resolves to its default (false)")
    func absentCameraMirror_resolvesToDefault() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            #expect(store.loadCameraMirror() == SettingsDefaults.cameraMirror)
            #expect(store.loadCameraMirror() == false)
        }
    }

    // MARK: - Test 3: Isolated corrupt-heal (P1)

    /// A non-`Bool` value written under one key must heal to that key's default while the
    /// other key — saved to a non-default value — stays intact. Proves per-key isolation:
    /// corruption of one setting never resets another.
    @Test("corrupting one key heals to its default without affecting the other")
    func corruptOneKey_healsWithoutAffectingOther() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveShowMenuBarTimer(false)
            // Corrupt the cameraMirror key with a non-Bool value written externally.
            defaults.set("garbage", forKey: SettingsKeys.cameraMirror)

            #expect(store.loadCameraMirror() == SettingsDefaults.cameraMirror)
            #expect(store.loadShowMenuBarTimer() == false)
        }
    }

    // MARK: - Test 4: Saving one key does not affect the other (P1)

    @Test("saving cameraMirror leaves showMenuBarTimer at its default")
    func savingOneKey_doesNotAffectOther() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveCameraMirror(true)

            #expect(store.loadShowMenuBarTimer() == SettingsDefaults.showMenuBarTimer)
            #expect(store.loadCameraMirror() == true)
        }
    }

    // MARK: - Test 5: InMemorySettingsStore round-trip (P2)

    @Test("InMemorySettingsStore round-trips both keys")
    func inMemoryStore_roundTripsBothKeys() {
        let store = InMemorySettingsStore()
        #expect(store.loadShowMenuBarTimer() == SettingsDefaults.showMenuBarTimer)
        #expect(store.loadCameraMirror() == SettingsDefaults.cameraMirror)

        store.saveShowMenuBarTimer(false)
        store.saveCameraMirror(true)

        #expect(store.loadShowMenuBarTimer() == false)
        #expect(store.loadCameraMirror() == true)
    }
}
