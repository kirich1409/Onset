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

        let displays = content.displays.map { scDisplay in
            Self.makeDisplay(from: scDisplay)
        }

        // PII policy: log counts only, never displayIDs or resolution values.
        discoveryDisplayLogger.info("Display enumeration complete — count: \(displays.count)")
        return displays
    }

    // MARK: - Pure mapper (testability seam)

    /// Produces a `Display` from a raw `SCDisplay`.
    ///
    /// Pixel dimensions are sourced from `CGDisplayCopyDisplayMode` — not from
    /// `SCDisplay.width`/`.height` which are in **points**, not pixels.
    ///
    /// - Parameter scDisplay: The `SCDisplay` from `SCShareableContent`.
    /// - Returns: An immutable `Display` snapshot.
    nonisolated static func makeDisplay(from scDisplay: SCDisplay) -> Display {
        let displayID = scDisplay.displayID
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = mode.map(\.pixelWidth) ?? 0
        let pixelHeight = mode.map(\.pixelHeight) ?? 0
        let refreshHz = mode.map(\.refreshRate) ?? 0.0

        return Display(
            displayID: displayID,
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
    ///   - pixelWidth: Physical pixel width (0 when the mode is unavailable).
    ///   - pixelHeight: Physical pixel height (0 when the mode is unavailable).
    ///   - refreshHz: Refresh rate in Hz (0.0 for built-in displays or unavailable mode).
    nonisolated static func makeDisplay(
        displayID: CGDirectDisplayID,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshHz: Double
    )
    -> Display {
        Display(
            displayID: displayID,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshHz: refreshHz
        )
    }
}
