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
    /// e.g. "3840×2160 @ 60 Гц", or `nil` when the screen pipeline did not run.
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
    /// Recording configuration carrying the user-selected output directory (#225).
    ///
    /// Defaults to `RecordingConfiguration.mvpDefault` when callers that predate output-folder
    /// selection do not provide an explicit config.
    let config: RecordingConfiguration
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

    /// The session-scoped output subdirectory of the most recent session.
    ///
    /// Set at stop time from `session.sessionDirectory` so `revealInFinder` can open the folder
    /// instead of individual files (#225). `nil` until the first stop completes.
    private(set) var lastSessionDirectory: URL?

    /// `true` when the most recent finished session had enough encoder-backpressure drops to
    /// warrant the post-stop warning (AC-9). Threshold from `RecordingConfiguration`.
    /// Derived from `lastDroppedFrames` — single source of truth, no lockstep pair needed.
    var lastDegradedWarning: Bool {
        self.lastDroppedFrames >= RecordingConfiguration.mvpDefault.postStopDropWarningThreshold
    }

    /// One-way degradation latch from the most recent finished session. `true` when the live HUD
    /// pill flashed `.degraded` at least once. Frozen at stop time; reset in
    /// `acknowledgeDegradedWarning()` and `start()`.
    private(set) var lastSessionEverDegraded = false

    /// Encoder-backpressure drop count from the most recent finished session, frozen at stop time.
    /// Used solely for message pluralization ("пропущено N кадров"). Not the alert gate (see
    /// `lastDegradedWarning`). Reset to 0 in `acknowledgeDegradedWarning()` and cleared on `start()`.
    private(set) var lastDroppedFrames = 0

    /// Dominant backpressure cause from the most recent finished session. Forwarded from
    /// `DropHealthSnapshot.dominantCause`. Reset to `.notDegraded` in `acknowledgeDegradedWarning()` and
    /// `start()`.
    private(set) var dominantCause: DropCause = .notDegraded

    /// Non-nil when the most recent session had a hard write failure (e.g. disk full). Contains
    /// the human-readable reason for the error alert. Distinct from `lastDegradedWarning` — a
    /// write failure means the file was not saved cleanly. Reset on `start()` / `acknowledgeWriteError()`.
    private(set) var lastWriteError: String?

    /// `true` when at least one post-stop alert is pending and has not yet been acknowledged.
    /// Used by `stop()` to decide whether to surface the main window after a menu-bar-origin stop
    /// (#131): a pending alert requires the window so `MainView` can present it.
    var hasPendingAlert: Bool {
        self.lastWriteError != nil || self.lastDegradedWarning
    }

    // MARK: - Dependencies (injected)

    /// Builds a `RecordingControlling` for a request. Live = `RecordingSession`; tests inject a fake.
    @ObservationIgnored
    private let sessionFactory: @Sendable (RecordingRequest) -> any RecordingControlling

    /// Fires a transient confirmation (local notification) when recording starts (#242).
    /// Tests inject `FakeRecordingStartNotifier` to assert the call without posting a real notification.
    @ObservationIgnored
    private let notifier: any RecordingStartNotifying

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
    private(set) var session: (any RecordingControlling)?

    /// The recording's origin, used to decide the post-stop phase.
    @ObservationIgnored
    private var origin: RecordingOrigin = .main

    /// The recording's start instant, used to derive `elapsed`.
    @ObservationIgnored
    private(set) var startedAt: Date?

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

    /// The task running `awaitCaptureActivation`. Stored so `stop()` / `handleHotKey()` can
    /// cancel the activation wait when the user aborts during the consent wait (#3 fix).
    @ObservationIgnored
    private var activationTask: Task<Bool, Never>?

    /// Set to `true` by `cancelActivation()` before cancelling `activationTask` so `start()`
    /// can distinguish a user-initiated cancel from a genuine denial / timeout.
    @ObservationIgnored
    private var activationCancelledByUser = false

    /// Seconds to wait for `captureActiveStream` to yield. Defaults to 30 s (production UX constant).
    /// Injectable for unit tests so the timeout path can be exercised without real wall-clock delay.
    @ObservationIgnored
    private let activationTimeoutSeconds: Double

    // MARK: - Init

    /// - Parameters:
    ///   - sessionFactory: Builds the session for a request (live = `RecordingSession`).
    ///   - notifier: Posts a transient start confirmation (#242). Tests inject a fake.
    ///   - activationTimeoutSeconds: Seconds to bound the first-frame wait (default: 30 s).
    ///     Pass a small value in unit tests to exercise the timeout path without wall-clock delay.
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
                config: request.config
            )
        },
        notifier: any RecordingStartNotifying = LiveRecordingStartNotifier(),
        activationTimeoutSeconds: Double = 30,
        revealInFinder: @escaping ([URL]) -> Void = { urls in
            // Open the session folder itself in Finder (AC-9 #225): `activateFileViewerSelecting`
            // on a directory-URL would select the folder inside its parent — `open(_:)` opens
            // the folder's contents instead.
            guard let url = urls.first else { return }
            let opened = NSWorkspace.shared.open(url)
            if !opened {
                // Log only the folder name — not the full path — to avoid logging the user's home directory.
                coordinatorLogger.error("NSWorkspace.open failed for '\(url.lastPathComponent)'")
            }
        }
    ) {
        self.sessionFactory = sessionFactory
        self.notifier = notifier
        self.activationTimeoutSeconds = activationTimeoutSeconds
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

    /// Clears the degradation latch and drop count after the user has acknowledged the alert (AC-9).
    /// Called by `MainView` on dismiss so the state does not persist across sessions.
    func acknowledgeDegradedWarning() {
        self.lastSessionEverDegraded = false
        self.lastDroppedFrames = 0
        self.dominantCause = .notDegraded
    }

    /// Clears `lastWriteError` after the user has acknowledged the alert.
    func acknowledgeWriteError() {
        self.lastWriteError = nil
    }

    // MARK: - Start (AC-3)

    /// Starts a recording for the given request.
    ///
    /// On success: hides the main window, opens the recording window, transitions to `.recording`,
    /// and spins the SOLE state subscription plus the elapsed-timer / drops-poll loop.
    /// On failure: rethrows the `RecordingError` for the caller's UI to surface (AC-6 / AC-11)
    /// and stays in the current phase.
    ///
    /// ### Screen-capture consent gate (#171)
    /// On macOS 26 `SCStream.startCapture()` returns **before** the user grants consent. The
    /// coordinator therefore waits for `session.captureActiveStream` to yield before flipping to
    /// `.recording` and opening the recording window. The stream yields on the first real screen
    /// frame (consent granted). If the stream finishes without yielding (terminal stop) or the
    /// bounded 30-second timeout elapses (silent denial — macOS may never fire a terminal stop),
    /// the session is stopped and `.captureDidNotActivate` is thrown so the caller can surface a
    /// suitable message. The elapsed timer starts at first-frame time, not at the point
    /// `session.start()` returns.
    ///
    /// The wait is cancellable: calling `stop()` or `handleHotKey()` during the consent wait
    /// unblocks activation and reverts silently (no error thrown to the caller).
    ///
    /// Phase 0 has no Record button; this is exercised by tests via the injected factory.
    func start(_ request: RecordingRequest) async throws { // swiftlint:disable:this function_body_length
        guard self.phase != .recording, !self.isStarting else {
            coordinatorLogger.warning("start() ignored — already recording or starting")
            return
        }
        self.isStarting = true
        // Reset the cancel flag immediately — before any `await` — so a stop() that races
        // session.start() (where activationTask is still nil) cannot be wiped on resume.
        self.activationCancelledByUser = false
        defer { self.isStarting = false }

        let session = self.sessionFactory(request)
        do {
            try await session.start(permissions: request.permissions)
        } catch {
            coordinatorLogger.error("RecordingSession.start failed: \(String(describing: error))")
            throw error
        }

        // Store the session now so cancelActivation() can reach it during the consent wait.
        self.session = session
        // Pre-populate checklist and origin so the recording window (if ever shown) has correct data.
        self.origin = request.origin
        self.checklist = request.checklist

        // Fix #2: if we exit before activation (error or Task cancellation), clean up the live
        // session so a subsequent start() cannot leak or overwrite it.
        var activated = false
        defer {
            // `activated` is set true only on the success path; all failure/cancellation paths leave
            // it false. nil-out the session so no zombie session survives after start() exits.
            if !activated {
                self.session = nil
            }
        }

        // Wait for the first real screen frame — this is when consent is actually granted (#171).
        // Fix #3: the wait is cancellable: cancelActivation() can be called from stop() / handleHotKey()
        // while isStarting is true. The activationTask is stored so those paths can cancel it.
        let activationTask = Task {
            await self.awaitCaptureActivation(
                session: session,
                timeoutSeconds: self.activationTimeoutSeconds
            )
        }
        self.activationTask = activationTask
        let captureActivated = await activationTask.value
        self.activationTask = nil

        // Check the cancel flag BEFORE the captureActivated guard so a stop() that raced the
        // activation window (including the session.start() suspension) is never dropped.
        // This covers two races the old placement missed:
        //   (a) stop() after emitCaptureActive() but before start() resumes (flag set, guard would pass)
        //   (b) stop() during session.start() suspension (activationTask nil → cancel no-op; flag set,
        //       but old code wiped it at the top of the wait block)
        if self.activationCancelledByUser {
            // User pressed stop / hotkey during the consent wait — revert silently (no error).
            coordinatorLogger.notice("Consent wait cancelled by user — reverting silently")
            self.activationCancelledByUser = false
            _ = await session.stop()
            return
        }
        guard captureActivated else {
            // Genuine denial or timeout: revert and throw so the UI can surface a message.
            _ = await session.stop()
            coordinatorLogger.notice("Capture did not activate (consent denied or timeout) — reverting (#171)")
            throw RecordingError.captureDidNotActivate
        }

        // Capture is live: mark activated (disarms the defer cleanup), adopt live state, open recording window.
        activated = true
        self.activateRecording(session: session, origin: request.origin)
        coordinatorLogger.info("Recording started — origin=\(String(describing: request.origin))")
    }

    /// Cancels an in-progress consent wait from `stop()` or `handleHotKey()`.
    ///
    /// Safe to call when not in the starting phase (no-op). Cancellation propagates into the
    /// `withTaskGroup` race: both children receive cancellation, both return `false` → activation
    /// returns `false`. The `activationCancelledByUser` flag lets `start()` revert silently
    /// (no error thrown) rather than surfacing a `.captureDidNotActivate` alert.
    private func cancelActivation() {
        guard self.isStarting else { return }
        coordinatorLogger.notice("Consent wait cancelled by user stop/hotkey")
        self.activationCancelledByUser = true
        self.activationTask?.cancel()
        self.activationTask = nil
    }

    /// Flips all observable state to "recording" and starts subscriptions + window choreography.
    ///
    /// Called exactly once per `start()` success path, after `captureActiveStream` yields (#171).
    /// `startedAt` is set HERE so the elapsed timer counts from the first real screen frame, not
    /// from when `SCStream.startCapture()` returned.
    private func activateRecording(session: any RecordingControlling, origin: RecordingOrigin) {
        // startedAt is set at activation (first real frame), not at session.start() (#171).
        self.startedAt = Date()
        self.elapsed = 0
        self.recordingState = .normal
        self.drops = DropCounters(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0)
        // Every source starts live; a graceful revoke (AC-12) flips the affected one(s) during the session.
        self.sourceLiveness = .allLive
        self.isStopping = false
        // Reset per-session degradation state — structural invariant: clean start.
        self.lastSessionEverDegraded = false
        self.lastDroppedFrames = 0
        self.dominantCause = .notDegraded
        self.lastWriteError = nil
        self.phase = .recording

        self.startStateSubscription(session)
        self.startRevocationSubscription(session)
        self.startTickLoop(session)

        // Window choreography (AC-3): hide main window on start; recording window opens
        // on demand from the menu bar («Открыть окно записи», #242 — menu-bar-first).
        // Start notifier fires below to confirm the recording has begun.
        self.dismissMainWindow()
        self.notifier.notifyRecordingStarted()
    }

    /// Awaits the first element from `session.captureActiveStream` with a bounded timeout.
    ///
    /// Returns `true` when the stream yields (capture is live), `false` when the stream finishes
    /// without yielding (consent denied or terminal stop) or the timeout elapses.
    ///
    /// Implemented as a racing `withTaskGroup` — the stream-consumer child and the timeout child
    /// race; the first result wins and the group is cancelled. This avoids any stored handle and is
    /// fully structured. `nonisolated` is not needed here because the coordinator is `@MainActor`
    /// and both children cross isolation via actor hops inside `Task`, not via `Task.detached`.
    private func awaitCaptureActivation(
        session: any RecordingControlling,
        timeoutSeconds: Double
    ) async
    -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            // Child 1: wait for the activation signal.
            group.addTask {
                var activated = false
                for await _ in session.captureActiveStream {
                    activated = true
                    break // single-consumer: we only need the first element
                }
                return activated
            }
            // Child 2: bounded timeout.
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return false // timed out
            }
            // The first child to finish wins; cancel the remaining child.
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
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

    /// The SOLE subscription to `session.sourceRevocationStream` (#39 / AC-12 / #197). Updates
    /// `sourceLiveness` on each `.sourceRevoked` / `.writerFailed` event, and calls `stop()` on
    /// `.allVideoSourcesLost`.
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

                case .writerFailed(.screen):
                    // Writer hard-fault: reuse the same "stopped" liveness indicator as AC-12.
                    self.sourceLiveness.screen = false
                    coordinatorLogger.error("#197: screen writer faulted — liveness updated")

                case .writerFailed(.camera):
                    // The microphone rides the camera AVCaptureSession: writer fault ends both.
                    self.sourceLiveness.camera = false
                    self.sourceLiveness.microphone = false
                    coordinatorLogger.error("#197: camera writer faulted — camera + mic liveness updated")

                case .allVideoSourcesLost:
                    coordinatorLogger.notice("AC-12: all video sources lost — stopping session")
                    await self.stop()
                }
            }
        }
    }

    /// One ~1 Hz loop: bumps `elapsed` from `startedAt` and polls the session's drop health. Both
    /// readouts tick at the same cadence, so they share one task (one cancel point).
    private func startTickLoop(_ session: any RecordingControlling) {
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let startedAt = self.startedAt {
                    self.elapsed = Int(Date().timeIntervalSince(startedAt))
                }
                self.drops = await session.currentDrops().counters
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
    func stop() async { // swiftlint:disable:this function_body_length
        // Fix #3: if the user presses stop/hotkey during the consent wait, cancel activation so
        // start() reverts promptly and silently (no error alert).
        if self.isStarting {
            self.cancelActivation()
            return
        }
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

        // Capture sessionDirectory before the await — nonisolated let, safe to read synchronously.
        let sessionDir = session.sessionDirectory

        let result = await session.stop()

        self.lastResult = result
        self.lastSessionDirectory = sessionDir
        self.drops = result.drops
        self.lastSessionEverDegraded = result.sessionEverDegraded
        self.lastDroppedFrames = result.drops.encoderBackpressureDrops
        self.dominantCause = result.dominantCause
        self.lastWriteError = result.writeFailureReason
        self.session = nil
        self.startedAt = nil

        // Transient finished phase, then return to the origin (spec lifecycle).
        self.phase = .finished
        // Reveal the session folder itself rather than individual files (#225):
        // the folder groups screen + camera files and survives an empty session gracefully.
        self.revealInFinder([sessionDir])
        // Log domain+code only (PII-free); writeFailureReason/localizedDescription may embed
        // the ~/Movies/Onset/<username> output path — #188.
        if let diagnostic = result.writeFailureDiagnostic {
            coordinatorLogger.error(
                "Recording finished with write failure — \(diagnostic, privacy: .public)"
            )
        } else if result.degradedWarning(threshold: RecordingConfiguration.mvpDefault.postStopDropWarningThreshold) {
            coordinatorLogger.notice(
                // swiftlint:disable:next line_length
                "Recording finished with degraded warning — backpressureDrops=\(result.drops.encoderBackpressureDrops) dominantCause=\(String(describing: result.dominantCause))"
            )
        }

        // Close the recording window, return to main or idle per origin.
        self.dismissRecordingWindow()
        switch self.origin {
        case .main:
            self.openMainWindow()
            self.phase = .main

        case .menuBar:
            // Open the main window when a post-stop alert is pending so MainView can present it
            // (#131). Without this, the window is never mounted and MainView's .onAppear / .onChange
            // never fire — the alert would be silently lost until the next manual window open.
            if self.hasPendingAlert {
                self.openMainWindow()
                self.phase = .main
            } else {
                self.phase = .idle
            }
        }

        self.isStopping = false
        // Session directory name (not full path) is safe to log — no home path (issue #188).
        let fileCount = result.outputURLs.count
        let originDescription = String(describing: self.origin)
        coordinatorLogger.info(
            "Recording stopped — files=\(fileCount) dir=\(sessionDir.lastPathComponent) origin=\(originDescription)"
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
        if self.isStarting {
            // Fix #3: hotkey during the consent wait cancels the activation wait silently.
            self.cancelActivation()
            coordinatorLogger.notice("Hotkey ⌘⌥⌃R — cancelling consent wait")
        } else if self.phase == .recording {
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
