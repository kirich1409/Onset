import AppKit
import CoreGraphics
import os
import ScreenCaptureKit

/// Logger is Sendable; nonisolated private let avoids a MainActor hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated private let discoveryDisplayLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DeviceDiscovery.Displays"
)

// MARK: - DeviceDiscovery namespace

/// Namespace for device-enumeration functions.
///
/// All members are `nonisolated` so they run off-actor. The caller is responsible
/// for querying permission status before calling these functions.
nonisolated enum DeviceDiscovery {}

// MARK: - Display enumeration

extension DeviceDiscovery {
    /// Enumerates all currently connected displays.
    ///
    /// - Parameter screenAuthorized: Pass `true` when the process holds screen-recording
    ///   permission (`CGPreflightScreenCaptureAccess()` returns `true`). Pass `false` to
    ///   receive an empty array without a system prompt or `SCShareableContent` call.
    ///
    /// - Returns: One `Display` snapshot per display reported by `SCShareableContent.current`.
    ///   Pixel dimensions are resolved from the display's current `CGDisplayModeRef`;
    ///   a display whose mode cannot be read contributes (pixelWidth: 0, pixelHeight: 0).
    ///
    /// - Throws: `RecordingError.displayDiscoveryFailed` when `SCShareableContent.current`
    ///   throws despite `screenAuthorized == true`.
    nonisolated static func displays(
        screenAuthorized: Bool
    ) async throws(RecordingError)
    -> [Display] {
        guard screenAuthorized else {
            discoveryDisplayLogger.debug("Display enumeration skipped — screen permission not granted")
            return []
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            discoveryDisplayLogger.error("SCShareableContent.current failed: \(error)")
            throw RecordingError.displayDiscoveryFailed(error)
        }

        // Resolve NSScreen names on MainActor in one hop — NSScreen.screens is @MainActor.
        // Building the full map here avoids a per-display MainActor hop (O(n) vs O(n²)).
        // CGDirectDisplayID is UInt32. The "NSScreenNumber" entry is an ObjC NSNumber bridged
        // to Swift; cast to Int (not UInt32 — UInt32 bridging silently returns nil) then widen.
        let screenNamesByID: [CGDirectDisplayID: String] = await MainActor.run {
            var map: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? Int {
                    let id = CGDirectDisplayID(screenNumber)
                    map[id] = screen.localizedName
                }
            }
            return map
        }

        let displays = content.displays.enumerated().map { index, scDisplay in
            Self.makeDisplay(from: scDisplay, screenNames: screenNamesByID, ordinal: index + 1)
        }

        // PII policy: log counts only, never displayIDs or resolution values.
        discoveryDisplayLogger.info("Display enumeration complete — count: \(displays.count)")
        return displays
    }

    // MARK: - Pure mapper (testability seam)

    /// Produces a `Display` from a raw `SCDisplay` with pre-resolved NSScreen names.
    ///
    /// Pixel dimensions are sourced from `CGDisplayCopyDisplayMode` — not from
    /// `SCDisplay.width`/`.height` which are in **points**, not pixels.
    ///
    /// Display name is resolved from `screenNames`; see `DisplayLabelMapper.name(localizedName:isBuiltin:ordinal:)`
    /// for the fallback chain.
    ///
    /// - Parameters:
    ///   - scDisplay: The `SCDisplay` from `SCShareableContent`.
    ///   - screenNames: A `[CGDirectDisplayID: String]` map built from `NSScreen.screens`
    ///     on the MainActor before this call.
    ///   - ordinal: 1-based index of this display in the enumeration; used in the
    ///     fallback name `"Дисплей N"` when no NSScreen match exists.
    nonisolated static func makeDisplay(
        from scDisplay: SCDisplay,
        screenNames: [CGDirectDisplayID: String],
        ordinal: Int
    )
    -> Display {
        let displayID = scDisplay.displayID
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = mode.map(\.pixelWidth) ?? 0
        let pixelHeight = mode.map(\.pixelHeight) ?? 0
        let refreshHz = mode.map(\.refreshRate) ?? 0.0
        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        let name = DisplayLabelMapper.name(
            localizedName: screenNames[displayID],
            isBuiltin: isBuiltin,
            ordinal: ordinal
        )

        return Display(
            displayID: displayID,
            name: name,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshHz: refreshHz
        )
    }

    /// Low-level testability seam.
    ///
    /// Constructs a `Display` directly from primitive values, bypassing `SCDisplay`
    /// and `CGDisplayMode`. This is the function unit tests call with synthetic data —
    /// `CGDisplayMode` is an opaque CoreGraphics type that cannot be instantiated
    /// synthetically, so the seam lives at the resolved-primitive level.
    ///
    /// - Parameters:
    ///   - displayID: The `CGDirectDisplayID` for this display.
    ///   - name: Human-readable display name (use ``DisplayLabelMapper/name(localizedName:isBuiltin:ordinal:)``
    ///     for the standard fallback chain, or pass a synthetic value in tests).
    ///   - pixelWidth: Physical pixel width (0 when the mode is unavailable).
    ///   - pixelHeight: Physical pixel height (0 when the mode is unavailable).
    ///   - refreshHz: Refresh rate in Hz (0.0 for built-in displays or unavailable mode).
    nonisolated static func makeDisplay(
        displayID: CGDirectDisplayID,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshHz: Double
    )
    -> Display {
        Display(
            displayID: displayID,
            name: name,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshHz: refreshHz
        )
    }
}
