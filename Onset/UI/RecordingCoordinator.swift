// swiftlint:disable file_length
import AppKit
import Foundation
import os

// MARK: - Logger

/// Sendable; nonisolated avoids a MainActor hop under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated private let coordinatorLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingCoordinator"
)

// MARK: - AppPhase

/// The app's top-level recording lifecycle phase, read by every recording-aware surface
/// (main window, recording window, menu bar). Owned solely by `RecordingCoordinator`.
enum AppPhase: Equatable {
    /// No windows open — menu-bar-only. The single entry point is the menu bar (#38).
    case idle
    /// The main screen is showing (device selection, Record button — #36).
    case main
    /// A recording is in progress; the recording window is showing (#37).
    case recording
    /// A recording just finished; the result is being surfaced (reveal / warning). Transient —
    /// the coordinator moves back to `.main` or `.idle` per the recording's origin.
    case finished
}

// MARK: - RecordingOrigin

/// Where a recording was started from — determines where to return after stop (spec lifecycle).
enum RecordingOrigin: Equatable {
    /// Started from the main window: return to `.main` after stop.
    case main
    /// Started from the menu bar with no window open: return to `.idle` after stop.
    case menuBar
}

// MARK: - RecordingChecklist

/// The read-only source descriptions captured at start, shown in the recording window's checklist
/// (#37) — resolved once at start because sources cannot change mid-recording (spec).
struct RecordingChecklist: Equatable {
    /// e.g. "3840×2160 @ 60 Hz", or `nil` when the screen pipeline did not run.
    let screenDescription: String?
    /// e.g. "MX Brio · 1080p60", or `nil` when no camera.
    let cameraDescription: String?
    /// e.g. "MacBook Pro — микрофон", or `nil` when recording without audio.
    let microphoneDescription: String?

    static let empty = Self(
        screenDescription: nil,
        cameraDescription: nil,
        microphoneDescription: nil
    )
}

// MARK: - SourceLiveness

/// Per-source liveness during recording, read by the recording-window checklist (#39 / AC-12).
///
/// Every source starts `true` (live) at recording start. A graceful revoke (display unplugged,
/// camera disconnected) flips the affected source to `false` so the checklist can show it stopped
/// while the surviving source keeps recording. The microphone rides the camera AVCaptureSession, so
/// a camera revoke flips BOTH `camera` and `microphone` (AC-12).
///
/// A plain `@MainActor` value type — it never leaves the coordinator (unlike `RecordingRevocation`,
/// which crosses the actor boundary and therefore hand-rolls its `nonisolated` conformance).
struct SourceLiveness: Equatable {
    /// `true` while the screen source is recording; `false` after a display-disconnect revoke.
    var screen: Bool
    /// `true` while the camera source is recording; `false` after a camera-disconnect revoke.
    var camera: Bool
    /// `true` while the microphone is capturing; `false` after a camera revoke (mic rides the camera).
    var microphone: Bool

    /// All sources live — the state every recording starts in.
    static let allLive = Self(screen: true, camera: true, microphone: true)
}

// MARK: - RecordingRequest

/// Everything the coordinator needs to start a session, assembled by the caller (#36 Record button,
/// in a later phase) from the resolved plan, devices, and permissions. Phase 0 exercises this only
/// through tests via the injected factory.
struct RecordingRequest {
    let plan: ResolvedRecordingPlan
    let display: Display
    let cameraDevice: CameraDevice?
    let cameraFormat: CameraFormat?
    let micDevice: MicrophoneDevice?
    let permissions: EffectivePermissions
    /// Source descriptions for the recording-window checklist (resolved by the caller, which knows
    /// the human-readable device names — the session deals in device IDs only).
    let checklist: RecordingChecklist
    /// Where the recording was started from (main window vs menu bar).
    let origin: RecordingOrigin
}

// MARK: - RecordingCoordinator

/// The single owner of app recording state, shared by the main window, recording window, and menu
/// bar (#36/#37/#38). All three are pure **readers** of its `@Observable` properties.
///
/// ### Sole subscriber of the session state stream
/// `RecordingControlling.recordingStateStream` is a **single-consumer** `AsyncStream` — two
/// iterators would split elements, not duplicate them. The coordinator is therefore the ONLY
/// subscriber: it consumes the one stream, owns the elapsed-timer + drops-poll loop, and
/// re-publishes `recordingState` / `drops` / `elapsed` as observable properties. The menu bar and
/// recording window NEVER subscribe to the stream or run their own timer — they read the coordinator.
///
/// ### Three stop paths funnel through `stop()`
/// Stop button (#37), global hotkey (PR2), and menu bar action (#38) all call `stop()`, which is
/// guarded against re-entrancy (synchronous `isStopping` flip before the first `await`) so the
/// teardown — reveal, warning, phase transition — runs exactly once even under concurrent calls.
///
/// Injected at the `OnsetApp` root via `@State` and passed to views by parameter (matches the
/// Onboarding pattern — no `@EnvironmentObject`).
@Observable
@MainActor
// swiftlint:disable:next type_body_length
final class RecordingCoordinator {
    // MARK: - Published state (read by all recording-aware views)

    /// The app's top-level lifecycle phase.
    private(set) var phase: AppPhase = .idle

    /// Live backpressure health, re-published from the session state stream (`.normal` until the
    /// first `.degraded` transition arrives).
    private(set) var recordingState: RecordingState = .normal

    /// Live cumulative drop counters, polled from the session (~1 Hz) while recording, then frozen
    /// to the final `RecordingResult.drops` on stop.
    private(set) var drops = DropCounters(
        encoderBackpressureDrops: 0,
        captureDrops: 0,
        cfrNormalizationDrops: 0
    )

    /// Elapsed recording time in whole seconds, derived from the start `Date` (~1 Hz).
    private(set) var elapsed = 0

    /// The read-only source checklist captured at start (recording-window display).
    private(set) var checklist: RecordingChecklist = .empty

    /// Live per-source liveness while recording (#39 / AC-12). All `true` at start; a graceful
    /// revoke flips the affected source(s) to `false` so the checklist can show a stopped source
    /// while the surviving one keeps recording. The recording window reads this; it never subscribes
    /// to the session's revocation stream itself (the coordinator is the sole consumer).
    private(set) var sourceLiveness: SourceLiveness = .allLive

    /// The terminal result of the most recent session (for reveal + warning). `nil` until the first
    /// stop completes.
    private(set) var lastResult: RecordingResult?

    /// `true` when the most recent finished session carried enough backpressure drops to warrant the
    /// AC-9 warning. Computed from `RecordingResult.degradedWarning` on stop.
    private(set) var lastDegradedWarning = false

    /// Non-nil when the most recent session had a hard write failure (e.g. disk full). Contains
    /// the human-readable reason for the error alert. Distinct from `lastDegradedWarning` — a
    /// write failure means the file was not saved cleanly. Reset on `start()` / `acknowledgeWriteError()`.
    private(set) var lastWriteError: String?

    // MARK: - Dependencies (injected)

    /// Builds a `RecordingControlling` for a request. Live = `RecordingSession`; tests inject a fake.
    @ObservationIgnored
    private let sessionFactory: @Sendable (RecordingRequest) -> any RecordingControlling

    /// Opens the recording window. Bound from the SwiftUI scene via `bindWindowActions` (env
    /// `openWindow` is not available in a plain class). Defaults to a no-op so unit tests need not
    /// wire it.
    @ObservationIgnored
    private var openRecordingWindow: () -> Void

    /// Hides the main window. Bound from the SwiftUI scene (env `dismissWindow`).
    @ObservationIgnored
    private var dismissMainWindow: () -> Void

    /// Closes the recording window. Bound from the SwiftUI scene.
    @ObservationIgnored
    private var dismissRecordingWindow: () -> Void

    /// Re-opens the main window. Bound from the SwiftUI scene.
    @ObservationIgnored
    private var openMainWindow: () -> Void

    /// Reveals the finished files in Finder. Injected so tests can observe it without touching
    /// `NSWorkspace`. Defaults to the live `NSWorkspace.shared.activateFileViewerSelecting`.
    @ObservationIgnored
    private let revealInFinder: ([URL]) -> Void

    /// Menu-bar «Начать запись» intent (#38). Installed by `MainView.onAppear`, cleared on disappear.
    /// Non-nil → delegates to `MainViewModel.record()` (all AC-2 guards there).
    /// Nil → menu bar falls back to opening the main window.
    @ObservationIgnored
    var menuBarRecordIntent: (() -> Void)?

    // MARK: - Runtime state

    /// The active session, retained for the duration of a recording.
    @ObservationIgnored
    private var session: (any RecordingControlling)?

    /// The recording's origin, used to decide the post-stop phase.
    @ObservationIgnored
    private var origin: RecordingOrigin = .main

    /// The recording's start instant, used to derive `elapsed`.
    @ObservationIgnored
    private var startedAt: Date?

    /// The SOLE subscription to `session.recordingStateStream`.
    @ObservationIgnored
    private var stateTask: Task<Void, Never>?

    /// The SOLE subscription to `session.sourceRevocationStream` (#39 / AC-12). Drives `sourceLiveness`
    /// updates and, on `.allVideoSourcesLost`, calls `stop()`.
    ///
    /// NEVER awaited in `stop()` (only cancelled + nil'd): `.allVideoSourcesLost` makes THIS task call
    /// `stop()`, so awaiting it from inside `stop()` would deadlock (a task awaiting itself). It writes
    /// nothing after stop and the `stop()` guard makes any late event a no-op, so awaiting is needless.
    @ObservationIgnored
    private var revocationTask: Task<Void, Never>?

    /// One loop ticking ~1 Hz: updates `elapsed` from `startedAt` and polls `currentDrops()`. Folded
    /// into a single task (both tick at the same cadence) to minimise task surface / cancellation.
    @ObservationIgnored
    private var tickTask: Task<Void, Never>?

    /// Re-entrancy guard for `start()`. Flipped synchronously before the first `await` so a concurrent
    /// call (e.g. double-click on the Record button) is a no-op and cannot leak a second session.
    @ObservationIgnored
    private var isStarting = false

    /// Re-entrancy guard for `stop()`. Flipped synchronously before the first `await` so a second
    /// stop path entering during the `await session.stop()` suspension is a no-op (the three stop
    /// paths all call `stop()`).
    @ObservationIgnored
    private var isStopping = false

    // MARK: - Init

    /// - Parameters:
    ///   - sessionFactory: Builds the session for a request (live = `RecordingSession`).
    ///   - revealInFinder: Reveals files (defaults to the live `NSWorkspace` call).
    ///
    /// Window actions default to no-ops and are installed later via `bindWindowActions(...)` from
    /// the SwiftUI scene, where the `openWindow` / `dismissWindow` env actions exist.
    init(
        sessionFactory: @escaping @Sendable (RecordingRequest) -> any RecordingControlling = { request in
            RecordingSession(
                plan: request.plan,
                display: request.display,
                cameraDevice: request.cameraDevice,
                cameraFormat: request.cameraFormat,
                micDevice: request.micDevice,
                config: .mvpDefault
            )
        },
        revealInFinder: @escaping ([URL]) -> Void = { urls in
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    ) {
        self.sessionFactory = sessionFactory
        self.openRecordingWindow = {}
        self.dismissMainWindow = {}
        self.dismissRecordingWindow = {}
        self.openMainWindow = {}
        self.revealInFinder = revealInFinder
    }

    // MARK: - Window action binding

    /// Installs the SwiftUI window actions. Called once from the scene's bridge view on appear, where
    /// the `openWindow` / `dismissWindow` env actions are available (a plain `@Observable` class
    /// cannot read them directly).
    func bindWindowActions(
        openRecordingWindow: @escaping () -> Void,
        dismissMainWindow: @escaping () -> Void,
        dismissRecordingWindow: @escaping () -> Void,
        openMainWindow: @escaping () -> Void
    ) {
        self.openRecordingWindow = openRecordingWindow
        self.dismissMainWindow = dismissMainWindow
        self.dismissRecordingWindow = dismissRecordingWindow
        self.openMainWindow = openMainWindow
    }

    // MARK: - Phase entry (window-driven, no recording)

    /// Marks that the main window is showing (called by the main scene on appear).
    func enterMain() {
        guard self.phase == .idle else { return }
        self.phase = .main
    }

    /// Clears `lastDegradedWarning` after the user has acknowledged the alert (AC-9). Called by
    /// `MainView` on dismiss so the flag does not persist across subsequent recordings.
    func acknowledgeDegradedWarning() {
        self.lastDegradedWarning = false
    }

    /// Clears `lastWriteError` after the user has acknowledged the alert.
    func acknowledgeWriteError() {
        self.lastWriteError = nil
    }

    // MARK: - Start (AC-3)

    /// Starts a recording for the given request. On success: hides the main window, opens the
    /// recording window, transitions to `.recording`, and spins the SOLE state subscription plus the
    /// elapsed-timer / drops-poll loop. On failure: rethrows the `RecordingError` for the caller's
    /// UI to surface (AC-6 / AC-11) and stays in the current phase.
    ///
    /// Phase 0 has no Record button; this is exercised by tests via the injected factory.
    func start(_ request: RecordingRequest) async throws {
        guard self.phase != .recording, !self.isStarting else {
            coordinatorLogger.warning("start() ignored — already recording or starting")
            return
        }
        self.isStarting = true
        defer { self.isStarting = false }

        let session = self.sessionFactory(request)
        do {
            try await session.start(permissions: request.permissions)
        } catch {
            coordinatorLogger.error("RecordingSession.start failed: \(String(describing: error))")
            throw error
        }

        // Started: adopt the session and reset live state.
        self.session = session
        self.origin = request.origin
        self.checklist = request.checklist
        self.startedAt = Date()
        self.elapsed = 0
        self.recordingState = .normal
        self.drops = DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0)
        // Every source starts live; a graceful revoke (AC-12) flips the affected one(s) during the session.
        self.sourceLiveness = .allLive
        self.isStopping = false
        // Reset per-session warning flags — structural invariant: every new session starts clean.
        self.lastDegradedWarning = false
        self.lastWriteError = nil
        self.phase = .recording

        self.startStateSubscription(session)
        self.startRevocationSubscription(session)
        self.startTickLoop(session)

        // Window choreography (AC-3): hide main, open recording.
        self.dismissMainWindow()
        self.openRecordingWindow()
        coordinatorLogger.info("Recording started — origin=\(String(describing: request.origin))")
    }

    /// The SOLE subscription to the session's single-consumer state stream. Re-publishes each
    /// transition into `recordingState` for all readers.
    private func startStateSubscription(_ session: any RecordingControlling) {
        let stream = session.recordingStateStream
        self.stateTask = Task { [weak self] in
            for await state in stream {
                self?.recordingState = state
            }
        }
    }

    /// The SOLE subscription to `session.sourceRevocationStream` (#39 / AC-12). Updates
    /// `sourceLiveness` on each `.sourceRevoked` event, and calls `stop()` on `.allVideoSourcesLost`.
    ///
    /// NEVER awaited in `stop()` — only cancelled and nil'd. `.allVideoSourcesLost` makes THIS task
    /// call `stop()`, so awaiting it from inside `stop()` would deadlock (a task awaiting itself).
    private func startRevocationSubscription(_ session: any RecordingControlling) {
        let stream = session.sourceRevocationStream
        self.revocationTask = Task { [weak self] in
            for await revocation in stream {
                guard let self else { return }
                switch revocation {
                case .sourceRevoked(.screen):
                    self.sourceLiveness.screen = false
                    coordinatorLogger.notice("AC-12: screen source revoked — liveness updated")

                case .sourceRevoked(.camera):
                    // The microphone rides the camera AVCaptureSession: camera revoke ends both.
                    self.sourceLiveness.camera = false
                    self.sourceLiveness.microphone = false
                    coordinatorLogger.notice("AC-12: camera source revoked — camera + mic liveness updated")

                case .allVideoSourcesLost:
                    coordinatorLogger.notice("AC-12: all video sources lost — stopping session")
                    await self.stop()
                }
            }
        }
    }

    /// One ~1 Hz loop: bumps `elapsed` from `startedAt` and polls the session's drop counters. Both
    /// readouts tick at the same cadence, so they share one task (one cancel point).
    private func startTickLoop(_ session: any RecordingControlling) {
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let startedAt = self.startedAt {
                    self.elapsed = Int(Date().timeIntervalSince(startedAt))
                }
                self.drops = await session.currentDrops()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Stop (AC-9) — funnel for all three stop paths

    /// Stops the active recording. Funnel for the three stop paths (button / hotkey / menu —
    /// AC-9). Re-entrancy-guarded so the teardown (reveal, warning, phase transition) runs exactly
    /// once even under concurrent calls: `isStopping` is flipped synchronously before the first
    /// `await`, so a second path entering during `await session.stop()` returns immediately. The
    /// underlying `RecordingSession.stop()` is itself memoized, so the double-await is harmless —
    /// the guard protects this coordinator's own teardown.
    func stop() async {
        guard self.phase == .recording, !self.isStopping, let session = self.session else { return }
        self.isStopping = true

        // Stop the live readouts BEFORE awaiting teardown so they don't tick against a stopping
        // session. The final drops/degraded come from the result, not a post-stop poll (the
        // session nils its monitor in stop()). Await the tick task fully (mirrors DropMonitor.stop())
        // so the poll loop cannot overwrite self.drops after the authoritative result is set below.
        // revocationTask is cancelled + nil'd but NOT awaited: .allVideoSourcesLost drives this very
        // stop() from inside revocationTask, so awaiting it would deadlock (a task awaiting itself).
        let tick = self.tickTask
        self.stateTask?.cancel()
        self.tickTask?.cancel()
        self.revocationTask?.cancel()
        self.stateTask = nil
        self.tickTask = nil
        self.revocationTask = nil
        await tick?.value

        let result = await session.stop()

        self.lastResult = result
        self.drops = result.drops
        self.lastDegradedWarning = result.degradedWarning
        self.lastWriteError = result.writeFailureReason
        self.session = nil
        self.startedAt = nil

        // Transient finished phase, then return to the origin (spec lifecycle).
        self.phase = .finished
        self.revealInFinder(result.outputURLs)
        if let writeError = result.writeFailureReason {
            coordinatorLogger.error(
                "Recording finished with write failure — \(writeError)"
            )
        } else if result.degradedWarning {
            coordinatorLogger.notice(
                "Recording finished with degraded warning — backpressureDrops=\(result.drops.encoderBackpressureDrops)"
            )
        }

        // Close the recording window, return to main or idle per origin.
        self.dismissRecordingWindow()
        switch self.origin {
        case .main:
            self.openMainWindow()
            self.phase = .main

        case .menuBar:
            self.phase = .idle
        }

        self.isStopping = false
        coordinatorLogger.info(
            "Recording stopped — files=\(result.outputURLs.count) origin=\(String(describing: self.origin))"
        )
    }

    // MARK: - Global hotkey (#67 / AC-9 third stop path)

    /// Toggle entry point for the global hotkey (#67, AC-9 third stop path) and any future
    /// single-gesture toggle. Recording in progress → stop(); otherwise delegate to the
    /// menu-bar record intent (installed by MainView when recording is possible), falling
    /// back to opening the main window when no intent is installed (onboarding / no window)
    /// — identical semantics to the #38 menu-bar action, so there is exactly one
    /// "start from a single gesture" code path.
    ///
    /// The Task wrapping stop() is required because `handleHotKey()` is synchronous
    /// (called from the Carbon callback via MainActor.assumeIsolated) while `stop()` is
    /// async. A structured Task inherits @MainActor isolation from the enclosing context.
    func handleHotKey() {
        if self.phase == .recording {
            Task { await self.stop() }
            coordinatorLogger.notice("Hotkey ⌘⌥⌃R — stopping active recording")
        } else if let intent = self.menuBarRecordIntent {
            intent()
            coordinatorLogger.info("Hotkey ⌘⌥⌃R — delegating to menuBarRecordIntent")
        } else {
            self.openMainWindow()
            coordinatorLogger.info("Hotkey ⌘⌥⌃R — no intent installed, opening main window")
        }
    }
}
