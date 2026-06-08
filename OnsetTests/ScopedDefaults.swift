import Foundation
import os
import Testing

// MARK: - In-memory UserDefaults

/// A `UserDefaults` subclass backed by a thread-safe dictionary.
///
/// Safety comes entirely from the three primitive method overrides —
/// `object(forKey:)`, `set(_:forKey:)`, and `removeObject(forKey:)` — which intercept
/// every read and write before they can reach the underlying domain. The superclass is
/// initialised with `suiteName: nil`, which binds to the STANDARD domain
/// (`UserDefaults.standard`); cfprefsd fully manages that domain. Any un-overridden
/// write path would therefore leak into `dev.androidbroadcast.OnsetTests.plist`. The
/// three-primitive design means all typed accessors (bool/integer/string/url/data/…)
/// funnel through the overridden `object` / `set(Any?)` on this platform, so there is no
/// un-overridden write path today. The self-test in `ScopedDefaultsTests` enforces this
/// contract: if a future un-overridden path escapes, the canary read on
/// `UserDefaults.standard` turns RED.
/// `@unchecked Sendable`: `UserDefaults` (superclass) is not `Sendable`, so the
/// compiler cannot verify conformance automatically. The `OSAllocatedUnfairLock` below
/// holds `storage` as its protected state — all three primitive overrides access it
/// exclusively through `withLockUnchecked`, matching the `FlagBox` pattern used
/// elsewhere in this test target. `withLockUnchecked` is required (not `withLock`)
/// because `[String: Any]` and the `Any?` return are not `Sendable`.
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    // `uncheckedState:` bypasses the Sendable constraint on the initial value, which is
    // needed because [String: Any] is not Sendable.
    private let lock = OSAllocatedUnfairLock(uncheckedState: [String: Any]())

    // MARK: - Primitives (all typed accessors funnel through these three)

    /// Stores `value` in the in-memory dictionary, or removes the key when `value` is `nil`.
    override func set(_ value: Any?, forKey key: String) {
        self.lock.withLockUnchecked { $0[key] = value }
    }

    /// Removes `key` from the in-memory dictionary.
    override func removeObject(forKey key: String) {
        self.lock.withLockUnchecked { $0[key] = nil }
    }

    /// Returns the value stored under `key`, or `nil` if absent.
    override func object(forKey key: String) -> Any? {
        self.lock.withLockUnchecked { $0[key] }
    }
}

// MARK: - Helper

/// Vends a fully in-memory `UserDefaults` instance and executes `body` with it.
///
/// Isolation is provided by `InMemoryUserDefaults`, whose three primitive overrides
/// intercept every read and write. No value ever reaches cfprefsd or
/// `~/Library/Preferences/`. Cleanup is implicit: the instance is deallocated when
/// `withScopedDefaults` returns.
///
/// Use this helper for every test that reads or writes `UserDefaults`. The only
/// exception is a test that exercises name-specific persistence behaviour; in that case
/// call `UserDefaults(suiteName:)` and `removePersistentDomain(forName:)` manually.
///
/// ## Example
///
/// ```swift
/// withScopedDefaults { defaults in
///     defaults.set("hello", forKey: "greeting")
///     #expect(defaults.string(forKey: "greeting") == "hello")
/// }
/// ```
func withScopedDefaults(body: (InMemoryUserDefaults) throws -> Void) rethrows {
    // InMemoryUserDefaults.init?(suiteName: nil) always succeeds — the force-unwrap
    // is safe because passing nil is explicitly documented to succeed by NSUserDefaults.
    // swiftlint:disable:next force_unwrapping
    try body(InMemoryUserDefaults(suiteName: nil)!)
}

/// Async overload of `withScopedDefaults(body:)` for tests whose body is `async`.
func withScopedDefaults(body: (InMemoryUserDefaults) async throws -> Void) async rethrows {
    // swiftlint:disable:next force_unwrapping
    try await body(InMemoryUserDefaults(suiteName: nil)!)
}

// MARK: - Self-tests

/// Verifies that `InMemoryUserDefaults` round-trips values and that writes do not
/// escape to `UserDefaults.standard`.
@Suite("ScopedDefaults — in-memory isolation")
struct ScopedDefaultsTests {
    /// All value types written through `set` must be readable back via their typed
    /// accessors. Covers the full range exercised by production code to confirm that
    /// every typed accessor funnels through the overridden primitives on this platform.
    @Test("InMemoryUserDefaults round-trips all value types")
    func inMemoryUserDefaults_roundTripsAllTypes() throws {
        let defaults = try #require(InMemoryUserDefaults(suiteName: nil))
        let url = try #require(URL(string: "https://example.com/onset"))
        let blob = Data([0xCA, 0xFE])

        defaults.set("hello", forKey: "string")
        defaults.set(42, forKey: "int")
        defaults.set(true, forKey: "bool")
        defaults.set(3.14, forKey: "double")
        defaults.set(url, forKey: "url")
        defaults.set(blob, forKey: "data")

        #expect(defaults.string(forKey: "string") == "hello")
        #expect(defaults.integer(forKey: "int") == 42)
        #expect(defaults.bool(forKey: "bool") == true)
        #expect(defaults.double(forKey: "double") == 3.14)
        #expect(defaults.url(forKey: "url")?.absoluteString == url.absoluteString)
        #expect(defaults.data(forKey: "data") == blob)
    }

    /// After `removeObject(forKey:)`, the key must be absent.
    @Test("InMemoryUserDefaults removes a key")
    func inMemoryUserDefaults_removesKey() throws {
        let defaults = try #require(InMemoryUserDefaults(suiteName: nil))
        defaults.set("canary", forKey: "key")
        defaults.removeObject(forKey: "key")
        #expect(defaults.object(forKey: "key") == nil)
    }

    /// Writes through `withScopedDefaults` must not escape to the standard domain.
    ///
    /// A leak via `suiteName: nil` would land in `UserDefaults.standard` (the standard
    /// domain = `dev.androidbroadcast.OnsetTests.plist`). This test writes a canary
    /// through the helper and then reads the SAME key directly from a separate,
    /// un-subclassed `UserDefaults.standard`. If any write path bypassed `storage` and
    /// reached the real domain, the standard store sees the canary — fail.
    @Test("withScopedDefaults does not leak writes to the standard domain")
    func withScopedDefaults_doesNotLeakToStandardDomain() {
        let probeKey = "scopedDefaultsIsolationProbe"
        withScopedDefaults { defaults in
            defaults.set("canary", forKey: probeKey)
        }
        let standard = UserDefaults.standard
        standard.synchronize()
        // Defensive cleanup runs on both pass and fail so a genuine leak does not
        // permanently poison the developer's standard domain.
        defer { standard.removeObject(forKey: probeKey) }
        #expect(standard.string(forKey: probeKey) == nil)
    }

    /// Each `withScopedDefaults` call must provide an isolated instance — writes in one
    /// body must not be visible in another.
    @Test("withScopedDefaults provides isolated instances per call")
    func withScopedDefaults_isolatesInstances() {
        var capturedDefaults: InMemoryUserDefaults?
        withScopedDefaults { defaults in
            defaults.set("value", forKey: "key")
            capturedDefaults = defaults
        }
        withScopedDefaults { defaults in
            // Different instance: key must be absent.
            #expect(defaults.object(forKey: "key") == nil)
            // Confirm it really is a different object.
            #expect(defaults !== capturedDefaults)
        }
    }
}
