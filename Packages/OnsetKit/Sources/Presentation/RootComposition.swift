import Application
import Domain

// MARK: - RootComposition

/// Composition root for the Onset application.
///
/// Creates all Application-layer objects and wires the dependency graph.
/// **No object is accessed as a global singleton** — everything is constructed here
/// and injected via initializers (AC: no hidden-singleton access).
///
/// Holds strong references to the coordinator, monitor, settings store, and permissions
/// provider for the lifetime of the application.
///
/// - Note: `ClockProviding` (#34) is not yet available. The coordinator receives
///   `clock: nil` until a concrete implementation lands. The composition root will
///   inject the real clock here once `#34` is merged — no other file needs to change.
///
/// - Note: Capture sources (#25/#26/#28) and encoding writers (#32) are per-session
///   factories until those Infrastructure implementations exist; the coordinator is
///   constructed now so the DI graph is wired and exercisable in tests.
///
/// - Note: The `permissions` parameter is the Domain-seam `PermissionsProviding` (issue #21).
///   The concrete `PermissionsManager` lives in Infrastructure and is constructed in the
///   **app target** (`onsetApp.swift`), which links Infrastructure directly. Presentation
///   never imports Infrastructure — it only speaks `PermissionsProviding`.
///   Future settings UI (#32) and the coordinator state machine (#36) will consume
///   this seam via their own injected parameters; the wiring point stays here.
@MainActor
public final class RootComposition {

    // MARK: - Application-layer graph

    public let settingsStore: SettingsStore
    public let healthMonitor: RuntimeHealthMonitor
    public let coordinator: RecordingSessionCoordinator

    /// The TCC permission provider.
    ///
    /// Held here for the app lifetime so the settings UI (#32) and coordinator
    /// state-machine gate (#36) can receive it via their own initializers.
    /// The concrete type is `PermissionsManager` (Infrastructure) in production and
    /// a test fake in unit tests — neither is imported here.
    public let permissions: any PermissionsProviding

    // MARK: - Initializer

    /// Assembles the full application-layer DI graph.
    ///
    /// - Parameter permissions: The `PermissionsProviding` implementation to use.
    ///   In production this is `PermissionsManager()` from Infrastructure, constructed
    ///   in the app target. In tests, pass a fake `PermissionsProviding`.
    ///
    /// All objects are constructed here and passed to their dependents via init —
    /// no object fetches its own dependencies from a global.
    public init(permissions: any PermissionsProviding) {
        let store = SettingsStore()
        let monitor = RuntimeHealthMonitor()
        let sessionCoordinator = RecordingSessionCoordinator(
            clock: nil,  // Concrete ClockProviding lands in #34
            healthMonitor: monitor,
            settingsStore: store
                // makeSources / makeWriter: default placeholder factories are used until
                // Infrastructure sources (#25/#26/#28) and writers (#32) are wired.
        )

        self.settingsStore = store
        self.healthMonitor = monitor
        self.coordinator = sessionCoordinator
        self.permissions = permissions
    }
}
