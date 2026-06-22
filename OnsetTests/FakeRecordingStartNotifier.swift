@testable import Onset
import UserNotifications

// MARK: - Fake

/// In-memory fake `RecordingStartNotifying` for unit tests.
///
/// All state is per-instance — safe under Swift Testing's parallel-by-default execution
/// (each `@Test` in a `@Suite struct` receives a fresh instance). The notifier is `@MainActor`,
/// so plain arrays/vars suffice for recording.
@MainActor
final class FakeRecordingStartNotifier: RecordingStartNotifying {
    // MARK: - Call tracking

    /// Number of times `notifyRecordingStarted()` was called.
    private(set) var notifyCallCount = 0

    /// Live critical incidents recorded, in call order.
    private(set) var criticalIncidents: [CriticalIncident] = []

    /// Interruption levels derived for each live critical incident, in call order (same index as
    /// `criticalIncidents`). Mirrors the live impl's `severity.interruptionLevel` mapping.
    private(set) var criticalIncidentLevels: [UNNotificationInterruptionLevel] = []

    /// Post-stop summary severities recorded, in call order.
    private(set) var postStopSeverities: [CriticalSeverity] = []

    // MARK: - RecordingStartNotifying

    /// Records the call synchronously; does not post any real notification.
    func notifyRecordingStarted() {
        self.notifyCallCount += 1
    }

    /// Records the incident and its tier-derived interruption level (shared mapping).
    func notifyCriticalIncident(_ incident: CriticalIncident) {
        self.criticalIncidents.append(incident)
        self.criticalIncidentLevels.append(incident.severity.interruptionLevel)
    }

    /// Records the post-stop max severity.
    func notifyPostStopSummary(severity: CriticalSeverity) {
        self.postStopSeverities.append(severity)
    }
}
