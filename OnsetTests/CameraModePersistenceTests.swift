import Foundation
@testable import Onset
import Testing

// MARK: - CameraModePersistenceTests

/// L2 tests for `PersistedCameraSelection` round-trips with a non-nil `CameraMode`.
///
/// Covers:
/// 1. Round-trip `.enabled(record, mode: nonNilMode)` — mode survives encode/decode.
/// 2. Round-trip `.enabled(record, mode: nil)` — nil sentinel survives encode/decode.
/// 3. Old-blob self-heal — a blob written by old app code (before `mode` was added) fails
///    Codable decode and is purged; `loadCamera()` returns `nil` for both calls.
///
/// `@MainActor` required: `UserDefaultsDeviceSelectionStore` and `DeviceSelectionKeys`
/// are `@MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@Suite("PersistedCameraSelection — CameraMode round-trips and self-heal")
@MainActor
struct CameraModePersistenceTests {
    // MARK: - Helpers

    private func makeRecord(id: String = "cam-1", name: String = "Test Camera") -> DeviceSelectionRecord {
        DeviceSelectionRecord(uniqueID: id, localizedName: name)
    }

    private func makeMode(width: Int32 = 1920, height: Int32 = 1080, fps: Int = 60) -> CameraMode {
        CameraMode(pixelWidth: width, pixelHeight: height, fps: fps)
    }

    // MARK: - Round-trip with non-nil mode

    @Test("saveCamera(.enabled, mode: nonNil) / loadCamera round-trips the mode")
    func saveAndLoad_enabledWithMode_roundTripsMode() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            let record = self.makeRecord()
            let mode = self.makeMode(width: 3840, height: 2160, fps: 30)

            store.saveCamera(.enabled(record, mode: mode))
            let loaded = store.loadCamera()

            if case let .enabled(restored, mode: restoredMode) = loaded {
                #expect(restored.uniqueID == "cam-1")
                #expect(restoredMode?.pixelWidth == 3840)
                #expect(restoredMode?.pixelHeight == 2160)
                #expect(restoredMode?.fps == 30)
            } else {
                Issue.record("Expected .enabled with mode, got \(String(describing: loaded))")
            }
        }
    }

    @Test("saveCamera(.enabled, mode: 1080p60) / loadCamera restores correct mode values")
    func saveAndLoad_1080p60Mode_roundTrips() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            let mode = self.makeMode(width: 1920, height: 1080, fps: 60)

            store.saveCamera(.enabled(self.makeRecord(), mode: mode))
            let loaded = store.loadCamera()

            if case let .enabled(_, mode: restoredMode) = loaded {
                #expect(restoredMode?.pixelWidth == 1920)
                #expect(restoredMode?.pixelHeight == 1080)
                #expect(restoredMode?.fps == 60)
            } else {
                Issue.record("Expected .enabled with mode, got \(String(describing: loaded))")
            }
        }
    }

    // MARK: - Round-trip with nil mode (Auto)

    @Test("saveCamera(.enabled, mode: nil) / loadCamera round-trips nil mode")
    func saveAndLoad_enabledWithNilMode_roundTripsNil() {
        withScopedDefaults { defaults in
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)

            store.saveCamera(.enabled(self.makeRecord(), mode: nil))
            let loaded = store.loadCamera()

            if case let .enabled(_, mode: restoredMode) = loaded {
                #expect(restoredMode == nil)
            } else {
                Issue.record("Expected .enabled with nil mode, got \(String(describing: loaded))")
            }
        }
    }

    // MARK: - Old-blob forward-compatibility

    /// Verifies that a blob written by an old app version (before `mode` was added to
    /// `PersistedCameraSelection.enabled`) decodes cleanly into the new schema.
    ///
    /// Swift's synthesized Codable for `case enabled(DeviceSelectionRecord, mode: CameraMode?)`
    /// uses `_0` for the first associated value and `mode` for the second. The old format
    /// (`case enabled(DeviceSelectionRecord)`) only wrote `_0` — the missing `mode` key decodes
    /// as `nil` in the new schema. This means old blobs are forward-compatible: no migration
    /// needed and no self-heal triggered.
    @Test("Old-format blob (no mode field) → decodes to .enabled with mode=nil (forward-compat)")
    func oldFormatBlob_decodesAsNilMode() {
        withScopedDefaults { defaults in
            // Old Codable layout: {"enabled":{"_0":{"uniqueID":"...","localizedName":"..."}}}
            // No "mode" key — Swift decodes the Optional<CameraMode> as nil.
            let oldJSON = #"{"enabled":{"_0":{"uniqueID":"cam-1","localizedName":"Old Camera"}}}"#
            defaults.set(Data(oldJSON.utf8), forKey: DeviceSelectionKeys.camera)

            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)
            let loaded = store.loadCamera()

            // Old blob decodes as Auto mode — NOT nil, NOT a decode error.
            if case let .enabled(record, mode: restoredMode) = loaded {
                #expect(record.uniqueID == "cam-1")
                #expect(restoredMode == nil) // graceful upgrade: old selection restores as Auto
            } else {
                Issue.record("Expected .enabled(nil mode), got \(String(describing: loaded))")
            }
        }
    }

    /// Directly decodes a JSON blob that was written by an old app version (before `mode` was
    /// added to `PersistedCameraSelection.enabled`) using `JSONDecoder` — NOT the store's
    /// self-heal path — to confirm forward-compatibility at the Codable layer.
    ///
    /// Swift synthesized Codable for `case enabled(DeviceSelectionRecord, mode: CameraMode?)`
    /// uses `_0` for the first associated value and `mode` for the second.
    /// A missing `mode` key decodes `Optional<CameraMode>` as `nil`, not as a decode error.
    @Test("Direct JSONDecoder on old-format blob (no mode key) → .enabled with mode=nil")
    func directDecode_oldFormatBlob_yieldsNilMode() throws {
        // Old Codable layout written by app before mode support was added.
        // Missing "mode" key — Swift decodes Optional<CameraMode> as nil (forward-compat).
        let oldJSON = #"{"enabled":{"_0":{"uniqueID":"cam-2","localizedName":"Legacy Cam"}}}"#
        let data = Data(oldJSON.utf8)
        // Use the decoder directly — bypasses store's self-heal path so this is a pure
        // Codable regression gate. If mode is NOT optional or CodingKeys change, this fails.
        let decoded = try JSONDecoder().decode(PersistedCameraSelection.self, from: data)
        if case let .enabled(record, mode: restoredMode) = decoded {
            #expect(record.uniqueID == "cam-2")
            // Missing key → nil, not a decode error.
            #expect(restoredMode == nil)
        } else {
            Issue.record("Expected .enabled(nil mode) from direct decode, got \(decoded)")
        }
    }

    @Test("Raw garbage blob → loadCamera returns nil and purges blob")
    func garbageBlob_returnsNilAndPurgesBlob() {
        withScopedDefaults { defaults in
            defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: DeviceSelectionKeys.camera)
            let store = UserDefaultsDeviceSelectionStore(defaults: defaults)

            let first = store.loadCamera()
            let second = store.loadCamera()

            #expect(first == nil)
            #expect(second == nil)
            #expect(defaults.object(forKey: DeviceSelectionKeys.camera) == nil)
        }
    }

    // MARK: - Mode equality (nonisolated Equatable)

    @Test("CameraMode equality — same values are equal")
    func cameraMode_sameValues_areEqual() {
        let lhs = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60)
        let rhs = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60)
        #expect(lhs == rhs)
    }

    @Test("CameraMode equality — different fps is not equal")
    func cameraMode_differentFps_areNotEqual() {
        let mode30 = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 30)
        let mode60 = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 60)
        #expect(mode30 != mode60)
    }

    @Test("CameraMode equality — different resolution is not equal")
    func cameraMode_differentResolution_areNotEqual() {
        let mode4K = CameraMode(pixelWidth: 3840, pixelHeight: 2160, fps: 30)
        let mode1080p = CameraMode(pixelWidth: 1920, pixelHeight: 1080, fps: 30)
        #expect(mode4K != mode1080p)
    }
}
