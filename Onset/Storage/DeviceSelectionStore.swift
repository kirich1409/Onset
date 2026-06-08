import Foundation
import os

// MARK: - Logger

/// Sendable; nonisolated avoids a MainActor hop under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated let deviceSelectionStoreLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DeviceSelectionStore"
)

// MARK: - DeviceSelectionRecord

/// A persistable record of a single device selection.
///
/// Stores the device's stable `uniqueID` (for re-matching after restart) and a
/// `localizedName` captured at persist time (for the disconnected-device notice).
///
/// The `localizedName` is stored in `UserDefaults` only — it is never written to the
/// logger (PII: device display names).
struct DeviceSelectionRecord: Codable, Equatable {
    /// The `AVCaptureDevice.uniqueID` — stable across launches for the same physical device.
    let uniqueID: String

    /// Human-readable device name captured at persist time via `AVCaptureDevice.localizedName`.
    ///
    /// Used exclusively for the disconnected-device notice in the UI. Never logged.
    let localizedName: String
}

// MARK: - PersistedCameraSelection

/// The tri-state value stored under `DeviceSelectionKeys.camera`.
///
/// Three distinct states map to three restore behaviors on launch:
/// - `.disabled` — user explicitly turned the camera OFF; do NOT auto-select on restore.
/// - `.enabled(_:mode:)` — user had a camera selected and enabled; re-match by `uniqueID`
///   and restore the selected mode (`nil` = Auto).
///
/// The absence of any value (`nil` from `loadCamera()`) is intentionally left as the
/// "first launch / never saved" sentinel, handled by the `.noSavedSelection` resolver branch.
///
/// ### Forward-compatibility with old blobs
/// Blobs written by old app versions (which used `case enabled(DeviceSelectionRecord)` without
/// a `mode` associated value) decode cleanly into this type. Swift's synthesized Codable stores
/// the first associated value under `_0` and the optional `mode` under `"mode"`. When the
/// `"mode"` key is absent, the Optional is decoded as `nil` — so old blobs restore with
/// `mode == nil` (Auto), requiring no migration code.
enum PersistedCameraSelection: Codable, Equatable {
    /// The user explicitly disabled the camera — camera must stay OFF on restore.
    case disabled

    /// The user had a specific camera enabled — restore to this device if present.
    ///
    /// `mode` carries the user's `CameraMode` selection, or `nil` for Auto mode.
    case enabled(DeviceSelectionRecord, mode: CameraMode?)
}

// MARK: - DeviceSelectionPersisting

/// Abstracts read/write access to persisted device selections.
///
/// Conforming types are responsible for encoding, decoding, and storing one record
/// per device role (camera, microphone). Conforming types are MainActor-isolated under
/// the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting; call sites already
/// on MainActor need no hop, off-actor callers cross one.
protocol DeviceSelectionPersisting: Sendable {
    /// Persists the camera selection tri-state, replacing any prior value.
    func saveCamera(_ selection: PersistedCameraSelection)

    /// Persists a microphone selection record, replacing any prior value.
    func saveMicrophone(_ record: DeviceSelectionRecord)

    /// Returns the most recently persisted camera selection, or `nil` if absent or corrupt.
    func loadCamera() -> PersistedCameraSelection?

    /// Returns the most recently persisted microphone selection, or `nil` if absent or corrupt.
    func loadMicrophone() -> DeviceSelectionRecord?

    /// Removes the persisted camera selection.
    func clearCamera()

    /// Removes the persisted microphone selection.
    func clearMicrophone()
}

// MARK: - UserDefaultsDeviceSelectionStore

/// Concrete `DeviceSelectionPersisting` backed by `UserDefaults`.
///
/// The `defaults` instance is injected at construction time so tests can pass an
/// `InMemoryUserDefaults` without touching the real `~/Library/Preferences/` store.
/// Production code uses the default `UserDefaults.standard`.
///
/// Records are JSON-encoded via `Codable`. A corrupt or missing blob is treated as
/// "no saved selection" — the store never throws or crashes on bad data.
struct UserDefaultsDeviceSelectionStore: DeviceSelectionPersisting {
    private let defaults: UserDefaults

    /// Creates a store backed by the given `UserDefaults` instance.
    ///
    /// - Parameter defaults: The `UserDefaults` to read from and write to.
    ///   Production callers omit this parameter to use `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Camera

    /// Encodes `selection` as JSON and writes it under `DeviceSelectionKeys.camera`.
    func saveCamera(_ selection: PersistedCameraSelection) {
        self.saveValue(selection, forKey: DeviceSelectionKeys.camera)
    }

    /// Decodes and returns the saved camera selection, or `nil` on missing/corrupt data.
    ///
    /// Returns `nil` (not a crash) on corrupt or legacy-format blobs (pre-`PersistedCameraSelection`
    /// raw `DeviceSelectionRecord` blobs fail `Codable` decode here). The self-heal path
    /// purges the corrupt blob so the caller receives `.noSavedSelection` on next load.
    func loadCamera() -> PersistedCameraSelection? {
        self.loadValue(forKey: DeviceSelectionKeys.camera)
    }

    /// Removes the camera selection from `UserDefaults`.
    func clearCamera() {
        self.defaults.removeObject(forKey: DeviceSelectionKeys.camera)
    }

    // MARK: - Microphone

    /// Encodes `record` as JSON and writes it under `DeviceSelectionKeys.microphone`.
    func saveMicrophone(_ record: DeviceSelectionRecord) {
        self.saveValue(record, forKey: DeviceSelectionKeys.microphone)
    }

    /// Decodes and returns the saved microphone record, or `nil` on missing/corrupt data.
    func loadMicrophone() -> DeviceSelectionRecord? {
        self.loadValue(forKey: DeviceSelectionKeys.microphone)
    }

    /// Removes the microphone selection from `UserDefaults`.
    func clearMicrophone() {
        self.defaults.removeObject(forKey: DeviceSelectionKeys.microphone)
    }

    // MARK: - Private helpers

    private func saveValue(_ value: some Encodable, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            self.defaults.set(data, forKey: key)
        } catch {
            deviceSelectionStoreLogger.error(
                "Failed to encode device selection for key '\(key)': \(String(describing: error))"
            )
        }
    }

    private func loadValue<T: Decodable>(forKey key: String) -> T? {
        guard let data = self.defaults.object(forKey: key) as? Data else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            deviceSelectionStoreLogger.error(
                "Failed to decode device selection for key '\(key)': \(String(describing: error))"
            )
            // Self-heal: purge the corrupt blob so the next launch starts clean.
            self.defaults.removeObject(forKey: key)
            deviceSelectionStoreLogger.notice("Purged corrupt device selection blob for key '\(key)'")
            return nil
        }
    }
}
