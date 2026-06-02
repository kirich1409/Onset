import AppKit
import Foundation
import os

/// Logger is Sendable; nonisolated private let avoids MainActor hop for logger calls
/// under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let relaunchLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "AppRelauncher"
)

/// Performs the self-relaunch required for screen-recording TCC to take effect.
///
/// **Mechanism (per spec — Mechanism авто-перезапуска):**
/// 1. Writes `pendingScreenGrantRelaunch = true` to `UserDefaults` as an anti-loop guard.
/// 2. Launches the same signed bundle via `NSWorkspace.openApplication`, passing the
///    transient argument `--post-screen-grant`.
/// 3. Terminates the current process.
///
/// **Anti-loop:** The composition root (Stage 5) reads the `pendingScreenGrantRelaunch` flag
/// on startup and passes it as context to `AppRouter.route`. After the process starts with
/// `--post-screen-grant`, the flag is cleared so no further relaunch is triggered.
///
/// **Why `createsNewApplicationInstance = true`:** Without it, `NSWorkspace.openApplication`
/// would re-activate the already-running instance rather than spawning a new process. We need
/// a new process so TCC picks up the granted access from a fresh launch.
@MainActor
final class AppRelauncher {
    // MARK: - UserDefaults key

    /// The key written before relaunch and cleared after startup with `--post-screen-grant`.
    nonisolated static let pendingScreenGrantRelaunchKey = "pendingScreenGrantRelaunch"

    /// The launch argument passed to the relaunched process.
    nonisolated static let postScreenGrantArg = "--post-screen-grant"

    // MARK: - Anti-loop guard

    /// Marks the pending relaunch in `UserDefaults` to prevent a relaunch loop.
    nonisolated static func markPendingRelaunch() {
        UserDefaults.standard.set(true, forKey: self.pendingScreenGrantRelaunchKey)
    }

    /// Clears the pending-relaunch flag. Call this at startup when `--post-screen-grant` is present.
    nonisolated static func clearPendingRelaunch() {
        UserDefaults.standard.removeObject(forKey: self.pendingScreenGrantRelaunchKey)
    }

    /// Returns `true` if a relaunch was previously initiated and not yet cleared.
    nonisolated static var isPendingRelaunch: Bool {
        UserDefaults.standard.bool(forKey: pendingScreenGrantRelaunchKey)
    }

    // MARK: - Relaunch

    /// Triggers a relaunch if the anti-loop guard allows it.
    ///
    /// Idempotent from the caller's perspective: if `isPendingRelaunch` is already `true`,
    /// no second relaunch is started. This happens when the polling loop fires on a tick
    /// after the first relaunch was already scheduled.
    func relaunchIfNeeded() {
        guard !Self.isPendingRelaunch else {
            relaunchLogger.debug("Relaunch already pending — skipping duplicate trigger")
            return
        }
        self.performRelaunch()
    }

    // MARK: - Private

    private func performRelaunch() {
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath, isDirectory: true)

        relaunchLogger.info("Preparing relaunch of \(bundleURL.lastPathComponent)")

        // Write the anti-loop flag before spawning the new instance so there is no
        // window where the flag is absent while the new process is starting.
        Self.markPendingRelaunch()

        let config = NSWorkspace.OpenConfiguration()
        // Spawn a new process rather than re-activating the already-running instance.
        // Without this flag, openApplication re-activates the running app instead of launching.
        config.createsNewApplicationInstance = true
        config.arguments = [Self.postScreenGrantArg]

        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: config
        ) { _, error in
            if let error {
                relaunchLogger.error("Failed to launch new instance: \(error)")
                // Revert the flag so the user is not stuck in a bad state.
                Self.clearPendingRelaunch()
            }
        }

        relaunchLogger.info("New instance launching — terminating current process")
        NSApp.terminate(nil)
    }
}
