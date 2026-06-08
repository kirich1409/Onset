import Foundation
@testable import Onset
import Testing

// MARK: - DeviceSelectionResolverTests

/// L2 tests for `DeviceSelectionResolver` (mic path) and `CameraOutcome` resolver.
///
/// Covers:
/// 1. All three `DeviceSelectionOutcome` branches (mic path — `resolve(saved:availableIDs:)`).
/// 2. All four `CameraOutcome` branches (camera path — `resolveCamera(saved:availableIDs:)`).
/// 3. Corrupt-blob self-heal in `UserDefaultsDeviceSelectionStore`.
///
/// `@MainActor` is required because `DeviceSelectionRecord` and `DeviceSelectionKeys`
/// are `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// Both resolvers are `nonisolated`; calling them from `@MainActor` is fine.
@Suite("DeviceSelectionResolver — pure resolver outcomes")
@MainActor
struct DeviceSelectionResolverTests {
    // MARK: - Helpers

    private func makeRecord(id: String, name: String = "Test Device") -> DeviceSelectionRecord {
        DeviceSelectionRecord(uniqueID: id, localizedName: name)
    }

    // MARK: - .restore

    /// When `saved.uniqueID` appears in `availableIDs`, the outcome is `.restore`.
    @Test("saved device present in list → restore outcome")
    func savedDevicePresent_returnsRestore() {
        let record = self.makeRecord(id: "cam-abc")
        let outcome = DeviceSelectionResolver.resolve(
            saved: record,
            availableIDs: ["cam-abc", "cam-xyz"]
        )
        #expect(outcome == .restore(uniqueID: "cam-abc"))
    }

    // MARK: - .disconnected

    /// When `saved.uniqueID` is absent from `availableIDs`, the outcome is `.disconnected`
    /// carrying the saved `localizedName` — even when other devices ARE present.
    @Test("saved device absent from list → disconnected outcome with saved name")
    func savedDeviceAbsent_returnsDisconnected() {
        let record = self.makeRecord(id: "cam-gone", name: "My Webcam")
        let outcome = DeviceSelectionResolver.resolve(
            saved: record,
            availableIDs: ["cam-other"]
        )
        #expect(outcome == .disconnected(savedName: "My Webcam"))
    }

    /// `.disconnected` is returned even when `availableIDs` is empty.
    @Test("saved device absent from empty list → disconnected outcome")
    func savedDeviceAbsent_emptyList_returnsDisconnected() {
        let record = self.makeRecord(id: "cam-gone", name: "Gone Camera")
        let outcome = DeviceSelectionResolver.resolve(saved: record, availableIDs: [])
        #expect(outcome == .disconnected(savedName: "Gone Camera"))
    }

    // MARK: - .noSavedSelection

    /// When `saved` is `nil` — first launch or cleared — the outcome is `.noSavedSelection`.
    @Test("nil saved record → noSavedSelection outcome")
    func noSavedRecord_returnsNoSavedSelection() {
        let outcome = DeviceSelectionResolver.resolve(
            saved: nil,
            availableIDs: ["cam-abc", "cam-xyz"]
        )
        #expect(outcome == .noSavedSelection)
    }

    /// `.noSavedSelection` is returned when `saved` is `nil` AND list is empty.
    @Test("nil saved record, empty list → noSavedSelection outcome")
    func noSavedRecord_emptyList_returnsNoSavedSelection() {
        let outcome = DeviceSelectionResolver.resolve(saved: nil, availableIDs: [])
        #expect(outcome == .noSavedSelection)
    }
}

// MARK: - CameraResolverTests

/// L2 tests for `DeviceSelectionResolver.resolveCamera(saved:availableIDs:)`.
///
/// Verifies all four `CameraOutcome` branches introduced to support camera enable/disable
/// persistence (#109 follow-up).
@Suite("DeviceSelectionResolver — camera outcome (resolveCamera)")
@MainActor
struct CameraResolverTests {
    private func makeRecord(id: String, name: String = "Test Camera") -> DeviceSelectionRecord {
        DeviceSelectionRecord(uniqueID: id, localizedName: name)
    }

    // MARK: - .disabled

    /// A persisted `.disabled` marker resolves to `.disabled` regardless of available devices.
    @Test("persisted disabled → disabled outcome with cameras present")
    func persistedDisabled_returnsDisabled() {
        let outcome = DeviceSelectionResolver.resolveCamera(
            saved: .disabled,
            availableIDs: ["cam-abc", "cam-xyz"]
        )
        #expect(outcome == .disabled)
    }

    /// A persisted `.disabled` marker resolves to `.disabled` when no cameras are available.
    @Test("persisted disabled → disabled outcome with empty camera list")
    func persistedDisabled_emptyCameraList_returnsDisabled() {
        let outcome = DeviceSelectionResolver.resolveCamera(saved: .disabled, availableIDs: [])
        #expect(outcome == .disabled)
    }

    // MARK: - .restore

    /// `.enabled(record, mode: nil)` with a matching ID resolves to `.restore(uniqueID:mode:)`.
    @Test("enabled record present in list → restore outcome")
    func enabledRecordPresent_returnsRestore() {
        let record = self.makeRecord(id: "cam-abc")
        let outcome = DeviceSelectionResolver.resolveCamera(
            saved: .enabled(record, mode: nil),
            availableIDs: ["cam-abc", "cam-xyz"]
        )
        #expect(outcome == .restore(uniqueID: "cam-abc", mode: nil))
    }

    // MARK: - .disconnected

    /// `.enabled(record, mode: nil)` with an absent ID resolves to `.disconnected`.
    @Test("enabled record absent from list → disconnected outcome with saved name")
    func enabledRecordAbsent_returnsDisconnected() {
        let record = self.makeRecord(id: "cam-gone", name: "My Webcam")
        let outcome = DeviceSelectionResolver.resolveCamera(
            saved: .enabled(record, mode: nil),
            availableIDs: ["cam-other"]
        )
        #expect(outcome == .disconnected(savedName: "My Webcam"))
    }

    // MARK: - .noSavedSelection

    /// `nil` saved value resolves to `.noSavedSelection` — first launch default.
    @Test("nil saved value → noSavedSelection outcome")
    func noSavedValue_returnsNoSavedSelection() {
        let outcome = DeviceSelectionResolver.resolveCamera(saved: nil, availableIDs: ["cam-abc"])
        #expect(outcome == .noSavedSelection)
    }
}

// MARK: - UserDefaultsDeviceSelectionStoreTests

/// L2 tests for `UserDefaultsDeviceSelectionStore`.
///
/// Covers round-trip persistence for camera tri-state (`PersistedCameraSelection`) and the
/// microphone `DeviceSelectionRecord`, plus the corrupt-blob self-heal path for both keys.
///
/// `@MainActor` required: `UserDefaultsDeviceSelectionStore` and `DeviceSelectionKeys`
/// are `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("UserDefaultsDeviceSelectionStore — persistence and self-heal")
@MainActor
struct UserDefaultsDeviceSelectionStoreTests {
    // MARK: - Round-trip

    @Test("saveCamera(.enabled) / loadCamera round-trips the record")
    func saveAndLoadCamera_enabled_roundTrips() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            let record = DeviceSelectionRecord(uniqueID: "cam-1", localizedName: "Built-in Camera")
            store.saveCamera(.enabled(record, mode: nil))
            let loaded = store.loadCamera()
            if case let .enabled(restored, mode: _) = loaded {
                #expect(restored.uniqueID == "cam-1")
            } else {
                Issue.record("Expected .enabled, got \(String(describing: loaded))")
            }
        }
    }

    @Test("saveCamera(.disabled) / loadCamera round-trips the disabled marker")
    func saveAndLoadCamera_disabled_roundTrips() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            store.saveCamera(.disabled)
            let loaded = store.loadCamera()
            #expect(loaded == .disabled)
        }
    }

    @Test("saveMicrophone / loadMicrophone round-trips the record")
    func saveAndLoadMicrophone_roundTrips() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            let record = DeviceSelectionRecord(uniqueID: "mic-1", localizedName: "Built-in Mic")
            store.saveMicrophone(record)
            let loaded = store.loadMicrophone()
            #expect(loaded?.uniqueID == "mic-1")
        }
    }

    // MARK: - Corrupt-blob self-heal (FIX 2 regression)

    /// Writing a non-JSON blob under the camera key must not crash. `loadCamera()` must
    /// return `nil` AND the corrupt blob must be purged so a subsequent `loadCamera()`
    /// also returns `nil` (not a decode error on every call).
    @Test("loadCamera with corrupt blob returns nil and purges the key")
    func loadCamera_corruptBlob_returnsNilAndPurgesKey() {
        withScopedDefaults { defaults in
            // Write non-decodable data directly under the production key.
            defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: DeviceSelectionKeys.camera)
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)

            let first = store.loadCamera()
            let second = store.loadCamera()

            #expect(first == nil)
            // Key must be purged — second call returns nil without decoding again.
            #expect(second == nil)
            #expect(defaults.object(forKey: DeviceSelectionKeys.camera) == nil)
        }
    }

    /// Same corrupt-blob self-heal for the microphone key.
    @Test("loadMicrophone with corrupt blob returns nil and purges the key")
    func loadMicrophone_corruptBlob_returnsNilAndPurgesKey() {
        withScopedDefaults { defaults in
            defaults.set(Data([0xDE, 0xAD]), forKey: DeviceSelectionKeys.microphone)
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)

            let first = store.loadMicrophone()
            let second = store.loadMicrophone()

            #expect(first == nil)
            #expect(second == nil)
            #expect(defaults.object(forKey: DeviceSelectionKeys.microphone) == nil)
        }
    }

    // MARK: - Clear

    @Test("clearCamera removes the record")
    func clearCamera_removesRecord() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            store.saveCamera(.enabled(DeviceSelectionRecord(uniqueID: "cam-1", localizedName: "Camera"), mode: nil))
            store.clearCamera()
            #expect(store.loadCamera() == nil)
        }
    }

    @Test("clearMicrophone removes the record")
    func clearMicrophone_removesRecord() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            store.saveMicrophone(DeviceSelectionRecord(uniqueID: "mic-1", localizedName: "Mic"))
            store.clearMicrophone()
            #expect(store.loadMicrophone() == nil)
        }
    }
}
