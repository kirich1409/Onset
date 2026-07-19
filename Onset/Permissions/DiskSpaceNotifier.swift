import os
import UserNotifications

// MARK: - Logger

nonisolated private let diskSpaceNotifierLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DiskSpaceNotifier"
)

// MARK: - Saved files

/// The output file location(s) confirmed saved when an auto-stop completes (AC-9).
///
/// Both fields are optional because a session may run screen-only or camera-only
/// (`RecordingResult.screen`/`.camera` are themselves optional per-pipeline projections) — the
/// coordinator (T-6) passes through whichever pipeline(s) actually produced a file.
///
/// A plain `Sendable` value type — never logged via `os.Logger` (paths may reveal
/// user directory structure); may be surfaced in a `UNNotificationContent` body,
/// which is user-facing text, not a diagnostic log.
struct DiskSpaceSavedFiles: Sendable, Equatable {
    /// Location of the saved screen recording file, or `nil` when the screen pipeline did not run.
    let screenURL: URL?
    /// Location of the saved camera recording file, or `nil` when the camera pipeline did not run.
    let cameraURL: URL?
}

// MARK: - Protocol

/// Posts local notifications for disk-space warnings and the resulting auto-stop (AC-3/AC-9/AC-12).
///
/// Decoupled from `DiskSpaceMonitor`/`RecordingCoordinator` via this protocol so tests can assert
/// the calls without posting a real `UNNotification`. Deliberately a separate file/protocol from
/// `RecordingStartNotifying` — same posting pattern, distinct concern and distinct notification
/// identifiers.
@MainActor
protocol DiskSpaceWarningNotifying: AnyObject {
    /// Called when disk space crosses into a `.warning` verdict (AC-3/AC-12).
    ///
    /// One-shot per crossing is the caller's responsibility (the monitor/coordinator guards
    /// duplicate posts across ticks) — this method always attempts to post.
    func notifyLowSpaceWarning(reason: DiskWarningReason)

    /// Called when recording auto-stopped due to a `.critical` disk verdict (AC-9).
    ///
    /// The notification names the low-space cause and confirms both output files were saved —
    /// a positive fact, not a silent abort.
    func notifyAutoStopped(reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles)
}

// MARK: - Live implementation

/// Posts local notifications for disk-space warnings and auto-stop confirmations.
///
/// Mirrors `LiveRecordingStartNotifier`: authorization is lazy (checked per call), posting is
/// fire-and-forget via an unstructured `Task`, and a `.denied` authorization status is a silent
/// fallback — recording is never affected by notification delivery.
@MainActor
final class LiveDiskSpaceWarningNotifier: DiskSpaceWarningNotifying {
    // MARK: - DiskSpaceWarningNotifying

    /// Schedules a low-space warning notification on a fire-and-forget `Task`.
    func notifyLowSpaceWarning(reason: DiskWarningReason) {
        Task { await self.postWarning(reason: reason) }
    }

    /// Schedules an auto-stop confirmation notification on a fire-and-forget `Task`.
    func notifyAutoStopped(reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles) {
        Task { await self.postAutoStopped(reason: reason, filesSaved: filesSaved) }
    }

    // MARK: - Private — warning

    private func postWarning(reason: DiskWarningReason) async {
        await self.post { _ in
            let content = UNMutableNotificationContent()
            content.title = "Мало места на диске"
            content.body = Self.warningBody(for: reason)
            return UNNotificationRequest(
                identifier: "dev.androidbroadcast.Onset.diskSpaceWarning",
                content: content,
                trigger: nil
            )
        }
    }

    private static func warningBody(for reason: DiskWarningReason) -> String {
        switch reason {
        case .outputEta:
            "Место на диске записи скоро закончится. Освободите место, чтобы запись не остановилась."

        case .outputFree:
            "На диске записи заканчивается свободное место."

        case .systemFree:
            "На системном диске заканчивается свободное место."
        }
    }

    // MARK: - Private — auto-stop

    private func postAutoStopped(reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles) async {
        await self.post { _ in
            let content = UNMutableNotificationContent()
            content.title = "Запись остановлена: мало места"
            content.body = Self.autoStopBody(for: reason, filesSaved: filesSaved)
            return UNNotificationRequest(
                identifier: "dev.androidbroadcast.Onset.diskSpaceAutoStopped",
                content: content,
                trigger: nil
            )
        }
    }

    private static func autoStopBody(for reason: DiskStopReason, filesSaved: DiskSpaceSavedFiles) -> String {
        // AC-9: name the cause AND confirm the saved file(s) — a positive fact, not a silent
        // abort. Not every session has both pipelines (screen-only is the common case) — list
        // whichever exist. The path is shown to the user in notification text, never passed to
        // os.Logger (see the logging calls below).
        let names = [filesSaved.screenURL, filesSaved.cameraURL].compactMap { $0?.lastPathComponent }
        let savedList = names.isEmpty ? "файлы" : names.joined(separator: ", ")
        return "\(self.stopCause(for: reason)) Сохранено: \(savedList)."
    }

    private static func stopCause(for reason: DiskStopReason) -> String {
        switch reason {
        case .outputEta:
            "Запись остановлена — на диске записи скоро закончится место."

        case .outputFree:
            "Запись остановлена — на диске записи закончилось свободное место."

        case .systemFree:
            "Запись остановлена — на системном диске закончилось свободное место."
        }
    }

    // MARK: - Private — shared posting

    /// Shared lazy-authorization + post flow, mirroring `LiveRecordingStartNotifier.postNotification()`.
    private func post(makeRequest: @MainActor @escaping (UNUserNotificationCenter) -> UNNotificationRequest) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if granted {
                    await self.schedule(makeRequest(center), center: center)
                }
                // Not granted → silent fallback; recording is not affected.
            } catch {
                diskSpaceNotifierLogger.error(
                    "UN requestAuthorization failed: \(error.localizedDescription)"
                )
            }

        case .authorized, .provisional:
            await self.schedule(makeRequest(center), center: center)

        case .denied, .ephemeral:
            // User denied notifications — silent fallback.
            break

        @unknown default:
            // New authorization status added in a future OS version — ignore safely.
            break
        }
    }

    private func schedule(_ request: UNNotificationRequest, center: UNUserNotificationCenter) async {
        do {
            try await center.add(request)
        } catch {
            diskSpaceNotifierLogger.error(
                "UN add notification failed: \(error.localizedDescription)"
            )
        }
    }
}
