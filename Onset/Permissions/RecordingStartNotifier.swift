import os
import UserNotifications

// MARK: - Logger

nonisolated private let notifierLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingStartNotifier"
)

// MARK: - Protocol

/// Fires a transient start confirmation when a recording begins (#242).
///
/// Decoupled from `RecordingCoordinator` via this protocol so tests can assert the call
/// without posting a real `UNNotification`.
@MainActor
protocol RecordingStartNotifying: AnyObject {
    /// Called synchronously from `activateRecording()` on the main actor.
    ///
    /// Implementations may schedule async work internally (e.g. request UN authorization
    /// then post a notification) but must not block the caller.
    func notifyRecordingStarted()
}

// MARK: - Live implementation

/// Posts a transient local notification to confirm recording has started (#242).
///
/// Authorization is lazy: each call checks the current `UNAuthorizationStatus`.
/// - `.notDetermined` → requests permission, then posts if granted.
/// - `.authorized` / `.provisional` → posts immediately.
/// - `.denied` → silent fallback (recording continues unaffected).
///
/// The notification request uses `trigger: nil` so it fires instantly.
/// Scheduling errors are logged at `.error` level; a failed post never aborts the recording.
@MainActor
final class LiveRecordingStartNotifier: RecordingStartNotifying {
    // MARK: - RecordingStartNotifying

    /// Schedules a "recording started" local notification on a fire-and-forget `Task`.
    ///
    /// The call returns immediately; the async authorization + posting work runs in the
    /// background without blocking `activateRecording()`.
    func notifyRecordingStarted() {
        Task { await self.postNotification() }
    }

    // MARK: - Private

    private func postNotification() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if granted {
                    await self.scheduleNotification(center: center)
                }
                // Not granted → silent fallback; recording is not affected.
            } catch {
                notifierLogger.error(
                    "UN requestAuthorization failed: \(error.localizedDescription)"
                )
            }

        case .authorized, .provisional:
            await self.scheduleNotification(center: center)

        case .denied, .ephemeral:
            // User denied notifications — silent fallback.
            break

        @unknown default:
            // New authorization status added in a future OS version — ignore safely.
            break
        }
    }

    private func scheduleNotification(center: UNUserNotificationCenter) async {
        let content = UNMutableNotificationContent()
        content.title = "Запись началась"
        content.body = "Onset записывает экран. Остановить можно из строки меню."
        let request = UNNotificationRequest(
            identifier: "dev.androidbroadcast.Onset.recordingStarted",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            notifierLogger.error(
                "UN add notification failed: \(error.localizedDescription)"
            )
        }
    }
}
