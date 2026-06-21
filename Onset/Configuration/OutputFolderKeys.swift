// MARK: - OutputFolderKeys

/// UserDefaults key constants for output folder persistence.
///
/// All keys share the `onset.output.` namespace. The namespace is intentionally
/// distinct from the `onset.device.` family — no legacy keys are reused.
enum OutputFolderKeys {
    /// Key for the user-selected base output directory path (`String`-encoded absolute path).
    ///
    /// Stored as a plain `String` path rather than a bookmark because Onset has no App Sandbox
    /// (no `com.apple.security.app-sandbox` entitlement), making security-scoped bookmarks
    /// unnecessary. A plain path survives UserDefaults round-trips without NSURL bookmark overhead.
    static let baseDirectory = "onset.output.baseDirectory"
}
