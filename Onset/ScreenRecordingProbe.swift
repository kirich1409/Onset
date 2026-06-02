import CoreGraphics
import os
import ScreenCaptureKit

// Logger is Sendable; nonisolated let makes it accessible from nonisolated methods
// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
private nonisolated let logger = Logger(subsystem: "dev.androidbroadcast.Onset", category: "ScreenRecordingProbe")

/// A lightweight diagnostic probe for TCC screen-recording permission.
///
/// Exposes two distinct permission signals so the spike can compare:
/// - ``preflight()``: `CGPreflightScreenCaptureAccess()` — the cached TCC value
///   maintained by the system's TCC daemon, updated at process launch and after explicit
///   system-settings changes. May be stale relative to a just-granted permission if the
///   running process has not observed the TCC update event.
/// - ``hasDisplaysViaShareableContent()``: `SCShareableContent.current.displays.isEmpty`
///   — the live ScreenCaptureKit truth. Calls the SCK daemon directly; returns `false`
///   on any error (permission denied, service unavailable, etc.).
///
/// Neither method mutates shared state, so the type is a `Sendable` struct rather than
/// an actor. Both methods are safe to call from any isolation context.
struct ScreenRecordingProbe: Sendable {

    // MARK: - Preflight (cached TCC)

    /// Returns the current value of `CGPreflightScreenCaptureAccess()`.
    ///
    /// This value reflects the TCC database entry at process launch and is updated
    /// when the system delivers a TCC notification. It may be stale for a running
    /// process that has not yet received the update after the user grants access.
    nonisolated func preflight() -> Bool {
        let result = CGPreflightScreenCaptureAccess()
        logger.debug("CGPreflightScreenCaptureAccess → \(result)")
        return result
    }

    // MARK: - SCShareableContent (live daemon truth)

    /// Returns `true` if `SCShareableContent.current` provides at least one display.
    ///
    /// Uses `SCShareableContent.current` (the Swift async property bridged from
    /// `+getShareableContentWithCompletionHandler:` via `NS_SWIFT_ASYNC_NAME(getter:current())`,
    /// available macOS 12.3+). Any thrown error — permission denied, daemon unavailable —
    /// is treated as "no access" and returns `false`.
    nonisolated func hasDisplaysViaShareableContent() async -> Bool {
        do {
            let content = try await SCShareableContent.current
            let count = content.displays.count
            logger.debug("SCShareableContent.current.displays.count → \(count)")
            return count > 0
        } catch {
            logger.debug("SCShareableContent.current threw: \(error)")
            return false
        }
    }

    // MARK: - One-shot access request

    /// Calls `CGRequestScreenCaptureAccess()` exactly once.
    ///
    /// This may present a system prompt on first call. Returns the access status
    /// immediately after the call. Callers are responsible for ensuring this is
    /// invoked at most once per user interaction (e.g., a button tap).
    @discardableResult
    nonisolated func requestAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        logger.info("CGRequestScreenCaptureAccess → \(granted)")
        return granted
    }
}
