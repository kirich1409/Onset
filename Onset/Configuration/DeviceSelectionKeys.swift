// MARK: - DeviceSelectionKeys

/// UserDefaults key constants for device-selection persistence.
///
/// All keys share the `onset.device.` namespace. The namespace is intentionally
/// distinct from any prior key families — no legacy keys are reused.
enum DeviceSelectionKeys {
    /// Key for the selected camera device record (`Data`-encoded `DeviceSelectionRecord`).
    static let camera = "onset.device.camera"

    /// Key for the selected microphone device record (`Data`-encoded `DeviceSelectionRecord`).
    static let microphone = "onset.device.microphone"
}
