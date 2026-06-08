// MARK: - CameraMode

/// A user-facing recording mode for a specific camera resolution and frame rate.
///
/// Camera modes are derived from a `CameraDevice`'s available formats by
/// `CameraFormatSelector.availableModes(from:config:)` — one mode per distinct resolution
/// within the policy-valid fps band `[config.minCameraFps, config.maxScreenFps]`.
///
/// Modes are ordered by decreasing pixel count so the highest-quality option
/// appears first in lists (e.g. "4K · 30 fps" before "1080p · 60 fps").
///
/// ### Equatable / Hashable — manual nonisolated witnesses
/// Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with `InferIsolatedConformances`
/// enabled, conformance declarations on types can be inferred `@MainActor` even when the
/// type itself is `nonisolated`. Declaring the conformances inside the primary type
/// definition (not in separate extensions) and writing explicit `nonisolated` witnesses
/// breaks the inference — see `CameraDevice` in `CaptureDeviceModels.swift` for the same pattern.
/// `Codable` synthesis is safe because it is only exercised from `@MainActor` persistence code.
nonisolated struct CameraMode: Codable, Equatable, Hashable {
    // MARK: - Coding keys

    /// Explicit coding keys — pins JSON field names to the property names as of this commit.
    ///
    /// Without explicit keys, synthesized Codable uses bare property names by default,
    /// so this enum documents the intent and prevents a silent decode break if a property
    /// is renamed in the future.
    private enum CodingKeys: String, CodingKey {
        case pixelWidth
        case pixelHeight
        case fps
    }

    // MARK: - Properties

    /// Frame width in pixels.
    let pixelWidth: Int32

    /// Frame height in pixels.
    let pixelHeight: Int32

    /// Target frame rate in frames per second.
    let fps: Int

    // swiftformat:disable redundantEquatable
    // Rationale: the `nonisolated` qualifier on these witnesses is required to prevent
    // the `InferIsolatedConformances` upcoming feature from tagging the conformance as
    // `@MainActor`. SwiftFormat's redundantEquatable rule would remove them because the
    // bodies are identical to what synthesis would produce — but synthesis omits `nonisolated`,
    // which triggers isolation errors at call sites outside the main actor.

    /// Manual `nonisolated` Equatable witness — see type-level doc for rationale.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.fps == rhs.fps
    }

    /// Manual `nonisolated` Hashable witness — see type-level doc for rationale.
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(self.pixelWidth)
        hasher.combine(self.pixelHeight)
        hasher.combine(self.fps)
    }
    // swiftformat:enable redundantEquatable
}
