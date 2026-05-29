import Domain
import Foundation

// MARK: - RecordingSessionCoordinator

/// The control plane for a recording session.
///
/// An `actor` that orchestrates `CaptureSource`s and `EncodingWriter`s. All
/// control-plane calls (start, stop, state queries) are isolated to this actor.
///
/// **Concurrency invariant:** This actor is the *control plane only*. Hot-path sample
/// delivery (capture callbacks → router → writers) runs on dedicated GCD serial queues
/// and must never cross into this actor's isolation — doing so would block capture.
///
/// **Dependencies** are injected via the initializer; nothing is fetched from a
/// global singleton inside method bodies (AC: no hidden-singleton access).
///
/// **Clock seam:** A concrete `ClockProviding` implementation does not yet exist (#34).
/// Inject `nil` until a concrete clock lands; the coordinator records the seam and will
/// use it when present. Pass a test-fake clock in unit tests to verify substitutability.
///
/// **State machine:** The full `idle → configuring → ready → recording → finalizing → done/error`
/// machine is issue #36. This skeleton carries a minimal internal status flag only.
public actor RecordingSessionCoordinator {

    // MARK: - Internal status (minimal skeleton; full state machine is #36)

    private enum Status {
        case idle
        case recording
        case stopped
    }

    private var status: Status = .idle

    // MARK: - Injected dependencies

    /// Reference clock for PTS synchronisation across sources.
    ///
    /// `nil` until a concrete `ClockProviding` is available (#34). Passed through the
    /// composition root; set to a test fake in unit tests.
    private let clock: (any ClockProviding)?

    /// Runtime health monitor — reads thermal state and (later) dropped-frame stats.
    private let healthMonitor: RuntimeHealthMonitor

    /// User preference store.
    private let settingsStore: SettingsStore

    /// Active capture sources. Empty until Infrastructure sources are wired (#25/#26/#28).
    private let sources: [any CaptureSource]

    /// Active encoding writers. Empty until Infrastructure writers are wired (#32).
    private let writers: [any EncodingWriter]

    // MARK: - Initializer

    /// Creates a `RecordingSessionCoordinator` with all dependencies injected.
    ///
    /// - Parameters:
    ///   - clock: The reference clock for PTS synchronisation. Pass `nil` until a
    ///     concrete `ClockProviding` exists (#34). Pass a test fake in unit tests.
    ///   - healthMonitor: Monitor for thermal state and degradation signals.
    ///   - settingsStore: Persistent user preference store.
    ///   - sources: Capture sources to drive. Defaults to empty (no Infrastructure yet).
    ///   - writers: Encoding writers to drive. Defaults to empty (no Infrastructure yet).
    public init(
        clock: (any ClockProviding)? = nil,
        healthMonitor: RuntimeHealthMonitor,
        settingsStore: SettingsStore,
        sources: [any CaptureSource] = [],
        writers: [any EncodingWriter] = []
    ) {
        self.clock = clock
        self.healthMonitor = healthMonitor
        self.settingsStore = settingsStore
        self.sources = sources
        self.writers = writers
    }

    // MARK: - Control-plane methods (skeletons; real logic is #36)

    /// Starts a recording session.
    ///
    /// Skeleton: logs the intent and sets an internal status flag.
    /// Full orchestration (configure → ready → recording state transitions,
    /// source start, writer begin-session) is issue #36.
    public func start() async {
        Log.general.info("RecordingSessionCoordinator: start requested (status=\(String(describing: self.status), privacy: .public))")
        status = .recording
    }

    /// Stops the current recording session.
    ///
    /// Skeleton: logs the intent and sets an internal status flag.
    /// Full orchestration (finalizing → done, writer finalize, source stop) is issue #36.
    public func stop() async {
        Log.general.info("RecordingSessionCoordinator: stop requested (status=\(String(describing: self.status), privacy: .public))")
        status = .stopped
    }
}
