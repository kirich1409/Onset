import Foundation

// MARK: - AppVersionFormatter

/// Pure static formatter that produces a human-readable version string for display in the UI.
///
/// `nonisolated` avoids a `MainActor` hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and enables direct use from tests without an actor context.
nonisolated enum AppVersionFormatter {
    // MARK: - Formatting

    /// Formats a marketing version and build number into a display string.
    ///
    /// Examples:
    /// - `"0.1.0"`, `"1"` → `"0.1.0 (1)"`
    /// - `""`, `"42"` → `"42"`
    /// - `""`, `""` → `"—"`
    ///
    /// - Parameters:
    ///   - short: `CFBundleShortVersionString` — the marketing version (e.g. `"0.1.0"`).
    ///   - build: `CFBundleVersion` — the build number (e.g. `"1"`).
    /// - Returns: A non-empty display string suitable for the menu bar version label.
    static func versionDisplay(short: String, build: String) -> String {
        let trimmedShort = short.trimmingCharacters(in: .whitespaces)
        let trimmedBuild = build.trimmingCharacters(in: .whitespaces)

        switch (trimmedShort.isEmpty, trimmedBuild.isEmpty) {
        case (false, false):
            return "\(trimmedShort) (\(trimmedBuild))"

        case (false, true):
            return trimmedShort

        case (true, false):
            return trimmedBuild

        case (true, true):
            return "—"
        }
    }

    // MARK: - Bundle accessor

    /// Reads the version string from `Bundle.main`.
    ///
    /// Returns `"—"` when either key is absent (unlikely in a correctly configured build,
    /// but avoids a crash on misconfigured test hosts or unsigned local builds).
    static var bundleVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return versionDisplay(short: short, build: build)
    }
}
