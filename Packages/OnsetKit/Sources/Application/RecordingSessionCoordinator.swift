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

    /// Per-session factory for capture sources.
    ///
    /// Capture sources and encoding writers are created PER RECORDING SESSION via these
    /// factories (real factories land in #36/#37); they are not app-lifetime instances.
    /// Called at the start of each recording session, not at coordinator init time.
    private let makeSources: @Sendable () -> [any CaptureSource]

    /// Per-session factory for the encoding writer.
    ///
    /// Capture sources and encoding writers are created PER RECORDING SESSION via these
    /// factories (real factories land in #36/#37); they are not app-lifetime instances.
    /// `EncodingWriter` (AVAssetWriter) is single-use per session; a new instance is
    /// produced here at the start of each recording session.
    private let makeWriter: @Sendable () throws -> any EncodingWriter

    // MARK: - Initializer

    /// Creates a `RecordingSessionCoordinator` with all dependencies injected.
    ///
    /// - Parameters:
    ///   - clock: The reference clock for PTS synchronisation. Pass `nil` until a
    ///     concrete `ClockProviding` exists (#34). Pass a test fake in unit tests.
    ///   - healthMonitor: Monitor for thermal state and degradation signals.
    ///   - settingsStore: Persistent user preference store.
    ///   - makeSources: Per-session factory producing the active capture sources.
    ///     Defaults to a closure returning an empty array (no Infrastructure yet).
    ///   - makeWriter: Per-session factory producing the encoding writer.
    ///     Defaults to a closure that throws a "not implemented" error (#37).
    public init(
        clock: (any ClockProviding)?,
        healthMonitor: RuntimeHealthMonitor,
        settingsStore: SettingsStore,
        makeSources: @Sendable @escaping () -> [any CaptureSource] = { [] },
        makeWriter: @Sendable @escaping () throws -> any EncodingWriter = { throw WriterNotImplementedError() }
    ) {
        self.clock = clock
        self.healthMonitor = healthMonitor
        self.settingsStore = settingsStore
        self.makeSources = makeSources
        self.makeWriter = makeWriter
    }

    // MARK: - Control-plane methods (skeletons; real logic is #36)

    /// Starts a recording session.
    ///
    /// Skeleton: guards against invalid transitions, logs the intent, and sets an internal
    /// status flag. Full orchestration (configure → ready → recording state transitions,
    /// source start, writer begin-session) is issue #36.
    public func start() async {
        guard status == .idle else {
            let currentStatus = String(describing: self.status)
            Log.general.warning("Coordinator: start ignored — already \(currentStatus, privacy: .public)")
            return
        }
        if clock == nil {
            // NFR-ERR: no silent failures — the unresolved clock seam is observable in logs.
            Log.general.warning("RecordingSessionCoordinator: no ClockProviding — PTS sync unavailable (#34)")
        }
        Log.general.info(
            "RecordingSessionCoordinator: start requested (status=\(String(describing: self.status), privacy: .public))"
        )
        status = .recording
    }

    /// Stops the current recording session.
    ///
    /// Skeleton: guards against invalid transitions, logs the intent, and sets an internal
    /// status flag. Full orchestration (finalizing → done, writer finalize, source stop) is issue #36.
    public func stop() async {
        guard status == .recording else {
            let currentStatus = String(describing: self.status)
            Log.general.warning(
                "RecordingSessionCoordinator: stop ignored — status \(currentStatus, privacy: .public)"
            )
            return
        }
        Log.general.info(
            "RecordingSessionCoordinator: stop requested (status=\(String(describing: self.status), privacy: .public))")
        status = .stopped
    }
}

// MARK: - WriterNotImplementedError

/// Thrown by the default `makeWriter` factory until a real writer is wired (#37).
@usableFromInline
struct WriterNotImplementedError: Error {
    @usableFromInline
    init() {}

    var localizedDescription: String {
        "EncodingWriter factory not yet implemented — wire a real writer in #37"
    }
}
