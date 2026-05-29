import Application
import Domain

// MARK: - RootComposition

/// Composition root for the Onset application.
///
/// Creates all Application-layer objects and wires the dependency graph.
/// **No object is accessed as a global singleton** — everything is constructed here
/// and injected via initializers (AC: no hidden-singleton access).
///
/// Holds strong references to the coordinator, monitor, and settings store for the
/// lifetime of the application.
///
/// - Note: `ClockProviding` (#34) is not yet available. The coordinator receives
///   `clock: nil` until a concrete implementation lands. The composition root will
///   inject the real clock here once `#34` is merged — no other file needs to change.
///
/// - Note: Capture sources (#25/#26/#28) and encoding writers (#32) are empty arrays
///   until those Infrastructure implementations exist; the coordinator is constructed
///   now so the DI graph is wired and exercisable in tests.
@MainActor
public final class RootComposition {

    // MARK: - Application-layer graph

    public let settingsStore: SettingsStore
    public let healthMonitor: RuntimeHealthMonitor
    public let coordinator: RecordingSessionCoordinator

    // MARK: - Initializer

    /// Assembles the full application-layer DI graph.
    ///
    /// All objects are constructed here and passed to their dependents via init —
    /// no object fetches its own dependencies from a global.
    public init() {
        let store = SettingsStore()
        let monitor = RuntimeHealthMonitor()
        let sessionCoordinator = RecordingSessionCoordinator(
            clock: nil,        // Concrete ClockProviding lands in #34
            healthMonitor: monitor,
            settingsStore: store,
            sources: [],       // Infrastructure sources land in #25/#26/#28
            writers: []        // Infrastructure writers land in #32
        )

        self.settingsStore = store
        self.healthMonitor = monitor
        self.coordinator = sessionCoordinator
    }
}
