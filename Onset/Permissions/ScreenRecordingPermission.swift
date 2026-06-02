import AppKit
import CoreGraphics
import os

/// Logger is Sendable; nonisolated private let avoids MainActor hop for logger calls
/// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let screenLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "ScreenRecordingPermission"
)

/// Wraps macOS TCC screen-recording permission: status, one-shot request, and Settings deep-link.
///
/// Detection uses `CGPreflightScreenCaptureAccess()` exclusively. The verification spike
/// (`swarm-report/tcc-screen-verify.md`) confirmed that `CGPreflight` and `SCShareableContent`
/// are in lockstep on macOS 26.x — there is no detection advantage to using `SCShareableContent`.
///
/// **Important:** `CGRequestScreenCaptureAccess()` may present a system prompt at most once.
/// After the first denial the prompt never reappears; the primary path is Settings + polling.
/// Never call `requestAccess()` in a loop.
struct ScreenRecordingPermission {
    // MARK: - Deep-link URL

    /// System Settings deep-link to the Screen Recording privacy section.
    static let settingsURL: URL = {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else {
            fatalError("ScreenRecordingPermission: invalid settings URL constant")
        }
        return url
    }()

    // MARK: - Status

    /// Returns the current screen-recording TCC status via `CGPreflightScreenCaptureAccess()`.
    ///
    /// This is a non-mutating read of the cached TCC value — no system prompt is presented.
    nonisolated func currentStatus() -> PermissionStatus {
        let granted = CGPreflightScreenCaptureAccess()
        screenLogger.debug("CGPreflightScreenCaptureAccess → \(granted)")
        return granted ? .authorized : .notDetermined
    }

    // MARK: - One-shot request

    /// Calls `CGRequestScreenCaptureAccess()` exactly once; may present a system prompt.
    ///
    /// Returns the access status immediately after the call. The caller is responsible for
    /// ensuring this is invoked at most once per user interaction (e.g., a button tap).
    ///
    /// - Returns: `true` when access was granted synchronously (rare; usually the prompt
    ///   must be dismissed first and the grant detected via polling on the next process start).
    @discardableResult
    nonisolated func requestAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        screenLogger.info("CGRequestScreenCaptureAccess → \(granted)")
        return granted
    }

    // MARK: - Settings deep-link

    /// Opens the Screen Recording privacy section in System Settings.
    @MainActor
    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
        screenLogger.info("Opened Screen Recording settings")
    }
}
