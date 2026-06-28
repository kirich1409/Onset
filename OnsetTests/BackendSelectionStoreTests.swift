import Foundation
@testable import Onset
import Testing

// MARK: - BackendSelectionStoreTests

/// L2 tests for `UserDefaultsBackendSelectionStore` persistence.
///
/// Covers:
/// 1. Happy-path round-trip: save then load returns the same `PersistedBackendSelection`.
/// 2. Clear removes the persisted value — subsequent load returns `nil`.
/// 3. Corrupt/legacy data stored under the key — load returns `nil` without crashing.
///
/// Every test goes through `withScopedDefaults` — no `.plist` file is written.
/// The suite is `@MainActor` because `UserDefaultsBackendSelectionStore` methods are
/// `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("BackendSelectionStore — UserDefaults persistence")
@MainActor
struct BackendSelectionStoreTests {
    // MARK: - Helpers

    private func makeStore(defaults: InMemoryUserDefaults) -> UserDefaultsBackendSelectionStore {
        UserDefaultsBackendSelectionStore(defaults: defaults)
    }

    /// A sample `PersistedBackendSelection` with all fields set.
    private var sampleSelection: PersistedBackendSelection {
        PersistedBackendSelection(source: "live", encoder: "live", writer: "live")
    }

    // MARK: - Test 1: Happy-path round-trip (P0)

    /// `save` followed by `load` must return a value equal to what was saved.
    @Test("save then load returns the same selection")
    func save_thenLoad_returnsSameSelection() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.save(self.sampleSelection)
            let loaded = store.load()
            #expect(loaded == self.sampleSelection)
        }
    }

    // MARK: - Test 2: Clear removes the persisted value (P1)

    /// After `clear`, `load` must return `nil`.
    @Test("clear then load returns nil")
    func clear_thenLoad_returnsNil() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.save(self.sampleSelection)
            store.clear()
            #expect(store.load() == nil)
        }
    }

    // MARK: - Test 3: Corrupt data under the key returns nil (P1)

    /// If raw garbage `Data` is written under the backend-selection key — simulating a
    /// corrupt or legacy defaults entry — `load` must return `nil` without crashing.
    ///
    /// The self-heal path in `loadValue` purges the corrupt blob; verifying that the
    /// key is absent after the load confirms the purge ran successfully.
    @Test("corrupt data under the key returns nil without crashing")
    func corruptDataUnderKey_returnsNil() async {
        await withScopedDefaults { defaults in
            // Write binary garbage that cannot be decoded as PersistedBackendSelection JSON.
            defaults.set(Data([0xFF, 0x00, 0xDE, 0xAD]), forKey: BackendSelectionKeys.selection)
            let store = self.makeStore(defaults: defaults)
            #expect(store.load() == nil, "corrupt blob must be treated as no saved selection")
            // Self-heal: the corrupt blob must be purged so the next load also returns nil.
            #expect(
                defaults.object(forKey: BackendSelectionKeys.selection) == nil,
                "corrupt blob must be removed from defaults after a failed decode"
            )
        }
    }
}
