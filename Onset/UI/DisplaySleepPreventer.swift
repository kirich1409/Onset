import Foundation
import os

// MARK: - Logger

nonisolated private let sleepPreventerLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DisplaySleepPreventer"
)

// MARK: - Protocol

/// Prevents the display and the system from idle-sleeping while a recording is in progress (#87).
///
/// Decoupled from `RecordingCoordinator` via this protocol so tests can assert begin/end calls
/// without touching the real `ProcessInfo` activity assertion.
@MainActor
protocol DisplaySleepPreventing: AnyObject {
    /// Begins preventing idle display/system sleep. Called once, from `activateRecording()`,
    /// after capture is confirmed live.
    ///
    /// Idempotent: calling this while already preventing sleep is a no-op — it never stacks a
    /// second assertion.
    func beginPreventingSleep()

    /// Ends any active sleep-prevention assertion. Called once, from the single stop-teardown
    /// path (`performStopTeardown()`), which also covers app-termination finalization.
    ///
    /// Idempotent: calling this when no assertion is active is a no-op.
    func endPreventingSleep()
}

// MARK: - Live implementation

/// Holds a `ProcessInfo` activity assertion for the lifetime of a recording (#87).
///
/// `ProcessInfo.beginActivity(options:reason:)` with `.idleDisplaySleepDisabled` and
/// `.idleSystemSleepDisabled` is the documented, memory-safe way to defer both display and
/// system idle sleep on macOS (available since macOS 10.9) — preferred here over the IOKit
/// `IOPMAssertionCreateWithName` C API, which would need `unsafe` C-interop annotations under
/// this target's strict memory-safety config for no functional benefit.
@MainActor
final class LiveDisplaySleepPreventer: DisplaySleepPreventing {
    // MARK: - Private state

    /// The active activity token, or `nil` when not currently preventing sleep.
    private var activityToken: (any NSObjectProtocol)?

    // MARK: - DisplaySleepPreventing

    func beginPreventingSleep() {
        guard self.activityToken == nil else { return }
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Recording screen and camera"
        )
        sleepPreventerLogger.info("Began preventing display/system idle sleep")
    }

    func endPreventingSleep() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
        sleepPreventerLogger.info("Ended display/system idle sleep prevention")
    }
}
