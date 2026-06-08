// MARK: - DisplayLabelMapper

/// Pure static mapper that formats a ``Display`` snapshot into a human-readable picker label.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// and makes every function directly testable without an actor context.
///
/// NSScreen name resolution (impure — requires MainActor) is intentionally kept outside
/// this type. Names are resolved once at enumeration time and stored on ``Display/name``;
/// this mapper only formats the already-resolved string.
nonisolated enum DisplayLabelMapper {
    // MARK: - Label formatting

    /// Formats a display snapshot as `"{Name} — {W}×{H} @ {Hz}"`.
    ///
    /// When `refreshHz` is 0.0 the `" @ {Hz}"` segment is omitted, yielding `"{Name} — {W}×{H}"`.
    ///
    /// The em-dash separator `" — "` and the absence of a unit after Hz match the design
    /// reference at `docs/design-ref/main/`.
    ///
    /// - Parameters:
    ///   - display: The display snapshot to format.
    /// - Returns: A human-readable string suitable for display in the screen picker.
    nonisolated static func label(for display: Display) -> String {
        self.label(
            name: display.name,
            pixelWidth: display.pixelWidth,
            pixelHeight: display.pixelHeight,
            refreshHz: display.refreshHz
        )
    }

    /// Low-level formatting seam — directly testable without a real `Display`.
    ///
    /// - Parameters:
    ///   - name: The resolved display name (e.g. "Внешний дисплей").
    ///   - pixelWidth: Physical pixel width.
    ///   - pixelHeight: Physical pixel height.
    ///   - refreshHz: Refresh rate in Hz; 0.0 means unknown/variable — omits the `@ Hz` segment.
    /// - Returns: Formatted label string.
    nonisolated static func label(
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshHz: Double
    )
    -> String {
        let res = "\(pixelWidth)×\(pixelHeight)"
        if refreshHz == 0.0 {
            return "\(name) — \(res)"
        }
        let refreshRate = Int(refreshHz.rounded())
        return "\(name) — \(res) @ \(refreshRate)"
    }

    // MARK: - Recording HUD formatting

    /// Formats a display snapshot as `"{W}×{H} @ {Hz} Гц"` for the recording HUD «Экран» row.
    ///
    /// Intentionally differs from ``label(pixelWidth:pixelHeight:refreshHz:name:)`` in two ways:
    /// - **No name** — the HUD is compact; the display name is omitted per `docs/design-ref/recording/`.
    /// - **«Гц» unit** — the Russian unit suffix matches the recording mockup
    ///   (`docs/design-ref/recording/Light.png`). The picker label has no unit per
    ///   `docs/design-ref/main/`. Do not unify these two formats — they serve different surfaces.
    ///
    /// When `refreshHz` is 0.0 the `" @ {Hz} Гц"` segment is omitted, yielding `"{W}×{H}"`.
    ///
    /// - Parameters:
    ///   - pixelWidth: Physical pixel width.
    ///   - pixelHeight: Physical pixel height.
    ///   - refreshHz: Refresh rate in Hz; 0.0 means unknown/variable — omits the `@ Hz Гц` segment.
    /// - Returns: A compact string for the recording window HUD screen row.
    nonisolated static func recordingScreenLabel(
        pixelWidth: Int,
        pixelHeight: Int,
        refreshHz: Double
    )
    -> String {
        let res = "\(pixelWidth)×\(pixelHeight)"
        if refreshHz == 0.0 {
            return res
        }
        let refreshRate = Int(refreshHz.rounded())
        return "\(res) @ \(refreshRate) Гц"
    }

    // MARK: - Name resolution

    /// Produces a display name from an optional `NSScreen.localizedName` and a fallback context.
    ///
    /// This pure function is separated from the impure `NSScreen` lookup so the fallback
    /// logic is independently testable.
    ///
    /// - Parameters:
    ///   - localizedName: The value of `NSScreen.localizedName` for the matching screen,
    ///     or `nil` when no `NSScreen` matches the display's `CGDirectDisplayID`.
    ///   - isBuiltin: `true` when `CGDisplayIsBuiltin(displayID)` returns a non-zero value.
    ///   - ordinal: 1-based index of this display in the enumeration; used only when
    ///     `localizedName` is absent and `isBuiltin` is `false`.
    /// - Returns: A non-empty display name.
    nonisolated static func name(
        localizedName: String?,
        isBuiltin: Bool,
        ordinal: Int
    )
    -> String {
        if let name = localizedName, !name.isEmpty {
            return name
        }
        return isBuiltin ? "Встроенный дисплей" : "Дисплей \(ordinal)"
    }
}
