import os
import UserNotifications

// MARK: - Logger

nonisolated private let notifierLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingStartNotifier"
)

// MARK: - Severity → interruption level

extension CriticalSeverity {
    /// The `UNNotificationInterruptionLevel` this severity tier maps to (spec "Системное уведомление").
    ///
    /// `hard` → `.timeSensitive` (breaks through Focus — the dominant recording scenario); `soft` →
    /// `.active`. SINGLE source of this mapping: both `LiveRecordingStartNotifier` and the test Fake
    /// derive the level from here so they cannot drift.
    nonisolated var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .hard:
            .timeSensitive

        case .soft:
            .active
        }
    }
}

// MARK: - Protocol

/// Fires a transient start confirmation when a recording begins (#242), plus active critical signals
/// (critical-recording-signals).
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

    /// Posts a LIVE critical-incident notification. The interruption level is derived by tier from
    /// `incident.severity` (`hard` → `.timeSensitive`, `soft` → `.active`).
    ///
    /// Non-blocking, same contract as `notifyRecordingStarted()`.
    /// - Parameter incident: The critical incident detected mid-recording.
    func notifyCriticalIncident(_ incident: CriticalIncident)

    /// Posts a POST-STOP summary notification keyed by the session's max severity (`hard` / `soft`).
    ///
    /// Non-blocking, same contract as `notifyRecordingStarted()`.
    /// - Parameter severity: The maximum severity seen across the session.
    func notifyPostStopSummary(severity: CriticalSeverity)
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
        Task { await self.postNotification(content: Self.startedContent(), identifier: Self.startedIdentifier) }
    }

    /// Schedules a live critical-incident notification on a fire-and-forget `Task`, with the
    /// interruption level derived by tier from `incident.severity`.
    func notifyCriticalIncident(_ incident: CriticalIncident) {
        let content = Self.criticalLiveContent(for: incident)
        Task { await self.postNotification(content: content, identifier: Self.criticalLiveIdentifier) }
    }

    /// Schedules a post-stop summary notification on a fire-and-forget `Task`, keyed by max severity.
    func notifyPostStopSummary(severity: CriticalSeverity) {
        let content = Self.postStopContent(for: severity)
        Task { await self.postNotification(content: content, identifier: Self.criticalPostStopIdentifier) }
    }

    // MARK: - Identifiers

    private static let startedIdentifier = "dev.androidbroadcast.Onset.recordingStarted"
    private static let criticalLiveIdentifier = "dev.androidbroadcast.Onset.criticalLive"
    private static let criticalPostStopIdentifier = "dev.androidbroadcast.Onset.criticalPostStop"

    // MARK: - Content builders

    private static func startedContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Запись началась"
        content.body = "Onset записывает экран. Остановить можно из строки меню."
        return content
    }

    private static func criticalLiveContent(for incident: CriticalIncident) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch incident {
        case .cameraLost(.cameraOnly):
            content.title = "Запись остановлена"
            content.body = "Камера отключена, запись остановлена."

        case .cameraLost(.cameraAndScreen):
            content.title = "Камера отключилась"
            content.body = "Камера отключилась во время записи; экран продолжает записываться."

        case .sustainedDrops, .fpsCollapse:
            content.title = "Проблемы записи"
            content.body = "Серьёзные потери кадров во время записи."
        }
        // Level by tier: hard → timeSensitive (breaks Focus); soft → active. Single mapping source.
        content.interruptionLevel = incident.severity.interruptionLevel
        return content
    }

    private static func postStopContent(for severity: CriticalSeverity) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        switch severity {
        case .hard:
            content.title = "Запись сохранена"
            content.body =
                "Запись сохранена, но были серьёзные проблемы. Подробности — в технической информации рядом с записью."

        case .soft:
            content.title = "Запись сохранена"
            content.body = "Камера отключилась во время записи; экран записан полностью."
        }
        content.interruptionLevel = severity.interruptionLevel
        return content
    }

    // MARK: - Private posting

    private func postNotification(content: UNMutableNotificationContent, identifier: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if granted {
                    await self.scheduleNotification(content: content, identifier: identifier, center: center)
                }
                // Not granted → silent fallback; recording is not affected.
            } catch {
                notifierLogger.error(
                    "UN requestAuthorization failed: \(error.localizedDescription)"
                )
            }

        case .authorized, .provisional:
            await self.scheduleNotification(content: content, identifier: identifier, center: center)

        case .denied, .ephemeral:
            // User denied notifications — silent fallback.
            break

        @unknown default:
            // New authorization status added in a future OS version — ignore safely.
            break
        }
    }

    private func scheduleNotification(
        content: UNMutableNotificationContent,
        identifier: String,
        center: UNUserNotificationCenter
    ) async {
        let request = UNNotificationRequest(
            identifier: identifier,
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
