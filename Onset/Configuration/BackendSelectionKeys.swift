// MARK: - BackendSelectionKeys

/// `UserDefaults` key constants for backend-selection persistence.
///
/// All keys share the `onset.backend.` namespace. The entire `PersistedBackendSelection`
/// struct is stored as a single JSON blob under `selection` — one key, not three.
enum BackendSelectionKeys {
    /// Key for the backend selection blob (`Data`-encoded `PersistedBackendSelection`).
    static let selection = "onset.backend.selection"
}
