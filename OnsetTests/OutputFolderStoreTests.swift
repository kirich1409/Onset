import Foundation
@testable import Onset
import Testing

// MARK: - OutputFolderStoreTests

/// L2 tests for `UserDefaultsOutputFolderStore` persistence (#225).
///
/// Covers:
/// 1. Happy-path round-trip: save then load returns the same URL.
/// 2. No saved value → `loadBaseDirectory()` returns `nil`.
/// 3. Clear removes the persisted value → subsequent load returns `nil`.
/// 4. Overwrite: saving a new URL replaces the previous one.
/// 5. Empty-string guard: an empty string written externally returns `nil`.
/// 6. Separate `InMemoryUserDefaults` instances are isolated from each other.
///
/// Every test goes through `withScopedDefaults` — no `.plist` file is written.
/// The suite is `@MainActor` because `UserDefaultsOutputFolderStore` methods are
/// `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("OutputFolderStore — UserDefaults persistence")
@MainActor
struct OutputFolderStoreTests {
    // MARK: - Helpers

    private func makeStore(defaults: InMemoryUserDefaults) -> UserDefaultsOutputFolderStore {
        UserDefaultsOutputFolderStore(defaults: defaults)
    }

    /// A stable, non-home-directory test URL.
    private var sampleURL: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "onset-output-folder-store-test", directoryHint: .isDirectory)
    }

    /// A second, distinct URL for overwrite tests.
    private var altURL: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "onset-output-folder-store-alt", directoryHint: .isDirectory)
    }

    // MARK: - Test 1: Happy-path round-trip (P0)

    /// `saveBaseDirectory` followed by `loadBaseDirectory` must return the same path.
    ///
    /// `URL` identity is compared by `path(percentEncoded: false)` because `URL` equality
    /// is case-sensitive on macOS and the store reconstructs the URL from a path string.
    @Test("save then load returns the same URL")
    func save_thenLoad_returnsSameURL() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveBaseDirectory(self.sampleURL)
            let loaded = store.loadBaseDirectory()
            #expect(loaded?.path(percentEncoded: false) == self.sampleURL.path(percentEncoded: false))
        }
    }

    // MARK: - Test 2: Load when nothing saved (P1)

    /// When no value has been persisted, `loadBaseDirectory` must return `nil` —
    /// the caller supplies the default `~/Movies/Onset/` fallback.
    @Test("load with no saved value returns nil")
    func load_withNoSavedValue_returnsNil() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            #expect(store.loadBaseDirectory() == nil)
        }
    }

    // MARK: - Test 3: Clear removes the persisted value (P1)

    /// After `clearBaseDirectory`, `loadBaseDirectory` must return `nil`.
    @Test("clear then load returns nil")
    func clear_thenLoad_returnsNil() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveBaseDirectory(self.sampleURL)
            store.clearBaseDirectory()
            #expect(store.loadBaseDirectory() == nil)
        }
    }

    // MARK: - Test 4: Overwrite replaces the previous value (P1)

    /// A second `saveBaseDirectory` call with a different URL must replace the first one.
    @Test("second save overwrites the first URL")
    func secondSave_overwritesFirstURL() async {
        await withScopedDefaults { defaults in
            let store = self.makeStore(defaults: defaults)
            store.saveBaseDirectory(self.sampleURL)
            store.saveBaseDirectory(self.altURL)
            let loaded = store.loadBaseDirectory()
            #expect(loaded?.path(percentEncoded: false) == self.altURL.path(percentEncoded: false))
        }
    }

    // MARK: - Test 5: Empty string guard (P3)

    /// If an empty string is written under the key (e.g. by external tooling or
    /// migration), `loadBaseDirectory` must return `nil` rather than a URL with an
    /// empty path — same as "no saved value" semantics.
    @Test("empty string stored externally is treated as no saved value")
    func emptyStringStoredExternally_treatedAsNil() async {
        await withScopedDefaults { defaults in
            defaults.set("", forKey: OutputFolderKeys.baseDirectory)
            let store = self.makeStore(defaults: defaults)
            #expect(store.loadBaseDirectory() == nil)
        }
    }

    // MARK: - Test 6: Separate defaults instances are isolated (P1)

    /// Two `UserDefaultsOutputFolderStore` instances backed by distinct
    /// `InMemoryUserDefaults` must not share state — a save in one is invisible to the other.
    @Test("stores backed by distinct defaults instances are isolated")
    func separateDefaultsInstances_areIsolated() async {
        await withScopedDefaults { defaults1 in
            await withScopedDefaults { defaults2 in
                let store1 = self.makeStore(defaults: defaults1)
                let store2 = self.makeStore(defaults: defaults2)

                store1.saveBaseDirectory(self.sampleURL)

                // store2 backed by a different defaults — must see nil.
                #expect(store2.loadBaseDirectory() == nil)
            }
        }
    }
}
