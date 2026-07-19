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
/// `nonisolated` (structs synthesize nonisolated witnesses — CLAUDE.md gotcha) so pure mappers
/// consuming it (`MenuBarLabelMapper`, #261) can reference `.allLive` as a default parameter
/// value without a MainActor hop; the coordinator itself still only ever mutates it on the
/// main actor.
nonisolated struct SourceLiveness: Equatable {
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

// MARK: - DiskStopReason+IdleWarning

extension DiskStopReason {
    /// Maps a critical disk-stop reason to its equivalent warning reason (T-7): at idle there is
    /// no session to auto-stop, so a `.critical` verdict is surfaced through the same
    /// `diskWarning` badge the in-recording path uses, one severity down.
    fileprivate var idleWarningReason: DiskWarningReason {
        switch self {
        case .outputEta: .outputEta
        case .outputFree: .outputFree
        case .systemFree: .systemFree
        }
    }
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
/// ### All stop paths funnel through one shared teardown handle
/// Stop button (#37), global hotkey (PR2), menu bar action (#38), the `.allVideoSourcesLost`
/// auto-stop, and app termination (#243) all call `stop()`, which memoizes a single teardown Task
/// (`stopTask`, flipped in lockstep with `isStopping` synchronously before the first `await`). Every
/// caller awaits the SAME handle, so the teardown — reveal, warning, phase transition — runs exactly
/// once even under concurrent calls, and app termination waits for whatever teardown is already in
/// flight rather than starting a fresh guarded call that would no-op (#243 defect 1).
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

    /// `true` from the ENTRY of `start()` through the COMPLETION of `stop()` — i.e. the whole
    /// startup window plus the recording — and `false` once fully stopped or after a start that
    /// reverted. Settings controls gated on `SettingApplyPolicy.nextRecordingStart` read this via
    /// `ControlAvailability` to grey out during the (possibly seconds-long) start/stop windows.
    ///
    /// Deliberately an OBSERVABLE STORED property, not a computed getter over the
    /// `@ObservationIgnored` `isStarting`/`isStopping` flags: a computed value would not trigger
    /// SwiftUI invalidation when those flags flip, and `phase` only reaches `.recording` at the
    /// END of `start()`, leaving the start window unobservable. It is reset on every `start()`
    /// failure/cancel path (so a denied first-run TCC consent does not leave the gate stuck
    /// `true`), but NOT by the `isStarting` `defer` — that resets a different variable and fires
    /// on the success path too, where this gate must stay `true`.
    private(set) var isRecordingActive = false

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

    // MARK: - Critical signals (critical-recording-signals, Phase C)

    /// The current DE-ESCALATING critical view for the menu-bar indicator (Phase D reads this as its
    /// second input). Holds the live incident the indicator should reflect RIGHT NOW, not the worst
    /// ever seen. Derived from two independent live concerns with different lifecycles, returning the
    /// higher-severity active one (spec §Архитектура "две оси — severity × persistence"):
    ///  - a camera-loss view (`cameraLossView`) is one-shot and sticky (the camera does not return) —
    ///    `cameraOnly` (hard, terminal) latches until stop; `cameraAndScreen` (soft) persists too so
    ///    its a11y-label doesn't flicker off on a quiet tick (AC-1);
    ///  - a windowed-hard view (`windowedHardView`, `sustainedDrops` / `fpsCollapse`) DE-ESCALATES to
    ///    `nil` once the detector stops firing — the indicator must not pulse "fire" hours after a
    ///    passed 10 s spike.
    ///
    /// A live windowed-hard always outranks a soft camera-loss; `cameraOnly` (hard, terminal) outranks
    /// everything. Distinct from `sessionMaxSeverityLatch`, which only climbs and feeds the post-stop
    /// branch — conflating them would stick the indicator on "fire" for the rest of the session.
    var liveCriticalView: CriticalIncident? {
        // hard outranks soft; among the two live concerns, return the higher-severity active incident.
        switch (self.cameraLossView, self.windowedHardView) {
        case let (cameraLoss?, windowedHard?):
            cameraLoss.severity == .hard ? cameraLoss : windowedHard

        case let (cameraLoss?, nil):
            cameraLoss

        case let (nil, windowedHard?):
            windowedHard

        case (nil, nil):
            nil
        }
    }

    /// Sticky one-shot camera-loss view (set by the revocation path, never de-escalated). Backs
    /// `liveCriticalView`.
    private(set) var cameraLossView: CriticalIncident?

    /// De-escalating windowed-hard view (set/cleared each detector tick). Backs `liveCriticalView`.
    private(set) var windowedHardView: CriticalIncident?

    /// The maximum `CriticalSeverity` seen across the WHOLE session — climbs only, never de-escalates.
    /// Feeds the POST-STOP summary branch exclusively (`notifyPostStopSummary`), never the live
    /// indicator. `nil` when no critical incident occurred (minor-drop sessions stay disk-only, #246).
    private(set) var sessionMaxSeverityLatch: CriticalSeverity?

    /// Pure fps-collapse detector value, stepped each tick on the monotonic session clock. Reset per
    /// session in `activateRecording`.
    @ObservationIgnored
    private var fpsDetector = FpsCollapseDetector()

    /// Pure sustained-drop detector value, evaluated each tick on the monotonic session clock. Reset
    /// per session in `activateRecording`.
    @ObservationIgnored
    private var sustainedDetector = SustainedDropDetector()

    /// Monotonic session-relative elapsed seconds at the most recent tick — captured so `stop()` can
    /// use it as the session duration for the post-stop drop-rate criterion (`evaluatePostStop`).
    /// `0` until the first tick. Reset per session.
    @ObservationIgnored
    private(set) var lastMonotonicElapsedSeconds: Double = 0

    /// Monotonic elapsed time at which the last LIVE critical notification was dispatched, per the
    /// per-window dedupe (`criticalNotificationDedupeSeconds`). `nil` when none dispatched this window.
    @ObservationIgnored
    private var lastLiveNotificationElapsedSeconds: Double?

    /// Session-level cap flags: each tier posts AT MOST one live notification per session. A recurrent
    /// windowed-hard after de-escalation updates the indicator but does NOT post a second Focus banner
    /// (spec §Дедуп "session-level cap"). Reset per session.
    @ObservationIgnored
    private var hardLiveNotificationPosted = false

    /// Soft-tier session cap counterpart of `hardLiveNotificationPosted`.
    @ObservationIgnored
    private var softLiveNotificationPosted = false

    /// `true` when a post-stop alert is pending and has not yet been acknowledged.
    /// Used by `stop()` to decide whether to surface the main window after a menu-bar-origin stop
    /// (#131): a pending alert requires the window so `MainView` can present it.
    ///
    /// Only the write-error alert remains a user-facing post-stop alert — frame-loss is now persisted
    /// as an on-disk technical report, not surfaced as an alert — so a degraded-but-saved session no
    /// longer forces the main window open.
    var hasPendingAlert: Bool {
        self.lastWriteError != nil
    }

    /// The active low-space warning reason, or `nil` when no warning is active (AC-3/AC-11/AC-12).
    /// Equatable-guarded by the tick loop — set once per NEW crossing, not re-posted on every tick
    /// the warning stays active; cleared once the monitor's cached verdict recovers to `.none`.
    private(set) var diskWarning: DiskWarningReason?

    /// `true` when the most recently finished session was auto-stopped by a `.critical` disk-space
    /// verdict (AC-9/spec #88) — the files were saved gracefully; this is NOT an error.
    ///
    /// Deliberately SEPARATE from `hasPendingAlert`/`lastWriteError`: those force-open the main
    /// window on a menu-bar-origin stop (#131), which is correct for a write ERROR but wrong here
    /// — a graceful low-space stop is surfaced out-of-window via the `UNNotification` (AC-9), not
    /// by forcing a window open. Reset on `start()`.
    private(set) var stoppedDueToLowSpace = false

    /// The pre-flight "≈ N мин" idle disk-space estimate (AC-1, T-7), or `nil` before the first
    /// `refreshIdleDiskEstimate` call completes. `MainViewModel` only DISPLAYS this — it never
    /// reads disk state itself; this coordinator owns `diskSpaceMonitor` and computes it off-main.
    private(set) var idleDiskEstimate: ETAEstimate?

    // MARK: - Dependencies (injected)

    /// Builds a `RecordingControlling` for a request. Live = `RecordingSession`; tests inject a fake.
    @ObservationIgnored
    let sessionFactory: @Sendable (RecordingRequest, ResolvedBackendSelection) -> any RecordingControlling

    /// Factory that vends the persisted recording-backend selection store on demand.
    ///
    /// Evaluated on every `start()` call (not at `init` time) so the default
    /// `UserDefaultsBackendSelectionStore()` is never constructed while the test host is
    /// initialising `OnsetApp` — matching the `makeStore:` / `makeOutputFolderStore:` convention
    /// used by `MainViewModel`.
    @ObservationIgnored
    private let makeBackendStore: () -> any BackendSelectionPersisting

    /// Fires a transient confirmation (local notification) when recording starts (#242).
    /// Tests inject `FakeRecordingStartNotifier` to assert the call without posting a real notification.
    @ObservationIgnored
    private let notifier: any RecordingStartNotifying

    /// Prevents display/system idle sleep for the duration of a recording (#87). Tests inject a fake
    /// to assert begin/end calls without touching the real `ProcessInfo` activity assertion.
    @ObservationIgnored
    private let sleepPreventer: any DisplaySleepPreventing

    /// Posts disk-space warning / auto-stop notifications (spec #88, T-5). Tests inject a fake to
    /// assert the calls without posting a real `UNNotification`.
    @ObservationIgnored
    private let diskWarningNotifier: any DiskSpaceWarningNotifying

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

    /// Owns the `readEvery` XPC-read throttle, EWMA smoothing, and cached disk-space verdict
    /// (spec #88, T-4). Reused across sessions: `reset()` clears its rolling state and bumps its
    /// generation token in `activateRecording()` so a stale in-flight refresh from a prior session
    /// cannot contaminate the new one.
    @ObservationIgnored
    private let diskSpaceMonitor: DiskSpaceMonitor

    /// The `DiskStopReason` that triggered the CURRENT teardown, set by the tick loop just before
    /// handing off to `stop()` on a `.critical` verdict; consumed (and cleared) at the end of
    /// `performStopTeardown` to decide whether to set `stoppedDueToLowSpace` and fire
    /// `notifyAutoStopped` (AC-9). `nil` for every other stop path (button/hotkey/menu,
    /// `.allVideoSourcesLost`, termination) — those must NOT be mis-attributed to low disk space.
    @ObservationIgnored
    private var pendingDiskStopReason: DiskStopReason?

    /// Re-entrancy guard for `start()`. Flipped synchronously before the first `await` so a concurrent
    /// call (e.g. double-click on the Record button) is a no-op and cannot leak a second session.
    @ObservationIgnored
    private var isStarting = false

    /// Re-entrancy guard for `stop()`. Flipped synchronously before the first `await` so a second
    /// stop path entering during the `await session.stop()` suspension is a no-op (the three stop
    /// paths all call `stop()`).
    ///
    /// Set and cleared IN LOCKSTEP with `stopTask` (both flip synchronously on the MainActor inside
    /// `sharedStopTask()` / at the end of `performStopTeardown()`), so the pair is a single logical
    /// state — never a second source of truth that can desync.
    @ObservationIgnored
    private var isStopping = false

    /// The single in-flight teardown handle, shared by ALL stop entry points (button / hotkey /
    /// menu, `.allVideoSourcesLost` auto-stop, and `finalizeForTermination`). Memoized so every
    /// caller awaits the SAME teardown rather than starting a fresh guarded `stop()` that would
    /// no-op against `isStopping` and return before the real teardown finished (#243 defect 1).
    /// Non-nil only while a teardown is running; nil'd at the end of `performStopTeardown()` and
    /// reset in `activateRecording()` so a fresh recording never inherits a stale handle.
    @ObservationIgnored
    private var stopTask: Task<Void, Never>?

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
    ///   - makeBackendStore: Factory that vends the persisted backend-selection store on demand
    ///     (default: `UserDefaults.standard`).
    ///   - sessionFactory: Builds the session for a request (live = `RecordingSession`).
    ///   - notifier: Posts a transient start confirmation (#242). Tests inject a fake.
    ///   - diskSpaceProvider: Reads free-space snapshots for the disk-space monitor (spec #88,
    ///     T-2). Live default reads real volumes; tests inject `FakeDiskSpaceProvider`.
    ///   - diskWarningNotifier: Posts low-space warning / auto-stop notifications (spec #88, T-5).
    ///     Tests inject a fake.
    ///   - diskSpaceClock: Monotonic time seam for the monitor's `readEvery` throttle. Tests inject
    ///     `FakeMonotonicClock` to advance it deterministically without wall-clock sleep.
    ///   - activationTimeoutSeconds: Seconds to bound the first-frame wait (default: 30 s).
    ///     Pass a small value in unit tests to exercise the timeout path without wall-clock delay.
    ///   - revealInFinder: Reveals files (defaults to the live `NSWorkspace` call).
    ///
    /// Window actions default to no-ops and are installed later via `bindWindowActions(...)` from
    /// the SwiftUI scene, where the `openWindow` / `dismissWindow` env actions exist.
    init(
        makeBackendStore: @escaping () -> any BackendSelectionPersisting = { UserDefaultsBackendSelectionStore() },
        sessionFactory: @escaping @Sendable (RecordingRequest, ResolvedBackendSelection)
            -> any RecordingControlling = { request, resolved in
                let encoderFactory: any EncoderFactory = switch resolved.encoder {
                case .live: LiveEncoderFactory()
                }
                let sourceFactory: any SourceFactory = switch resolved.source {
                case .live: LiveSourceFactory()
                }
                let writerFactoryBuilder: @Sendable (@escaping @Sendable (RecordingPipelineKind) -> URL)
                    -> any WriterFactory = { urlProvider in
                        switch resolved.writer {
                        case .live: LiveWriterFactory(configuration: request.config, urlProvider: urlProvider)
                        }
                    }
                return RecordingSession(
                    plan: request.plan,
                    display: request.display,
                    cameraDevice: request.cameraDevice,
                    cameraFormat: request.cameraFormat,
                    micDevice: request.micDevice,
                    config: request.config,
                    encoderFactory: encoderFactory,
                    writerFactoryBuilder: writerFactoryBuilder,
                    sourceFactory: sourceFactory
                )
            },
        notifier: any RecordingStartNotifying = LiveRecordingStartNotifier(),
        sleepPreventer: any DisplaySleepPreventing = LiveDisplaySleepPreventer(),
        diskSpaceProvider: any DiskSpaceProviding = LiveDiskSpaceProvider(),
        diskWarningNotifier: any DiskSpaceWarningNotifying = LiveDiskSpaceWarningNotifier(),
        diskSpaceClock: any MonotonicClock = SystemMonotonicClock(),
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
        self.makeBackendStore = makeBackendStore
        self.sessionFactory = sessionFactory
        self.notifier = notifier
        self.sleepPreventer = sleepPreventer
        self.diskWarningNotifier = diskWarningNotifier
        self.diskSpaceMonitor = DiskSpaceMonitor(
            provider: diskSpaceProvider,
            configuration: .mvpDefault,
            clock: diskSpaceClock
        )
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
        // Recording-active gate ON at entry — covers the whole startup window (see property doc).
        // Every failure/cancel path below resets it to false; the success path leaves it true.
        self.isRecordingActive = true
        // Reset the cancel flag immediately — before any `await` — so a stop() that races
        // session.start() (where activationTask is still nil) cannot be wiped on resume.
        self.activationCancelledByUser = false
        defer { self.isStarting = false }

        let resolved = RecordingBackendResolver.resolve(
            persisted: self.makeBackendStore().load(),
            supported: .allSupported
        )
        let session = self.sessionFactory(request, resolved)
        do {
            try await session.start(permissions: request.permissions)
        } catch {
            coordinatorLogger.error("RecordingSession.start failed: \(String(describing: error))")
            // This catch precedes the `if !activated` cleanup defer below, so reset the gate here.
            self.isRecordingActive = false
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
                // Revert the recording-active gate on every non-success exit (user cancel during
                // consent wait, denial, timeout) — the success path leaves it true until stop().
                self.isRecordingActive = false
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
        // Clear any stale teardown handle in lockstep with isStopping so a fresh recording never
        // inherits a completed stop() task from a prior session (keeps the isStopping/stopTask pair coherent).
        self.stopTask = nil
        // Reset per-session degradation state — structural invariant: clean start.
        self.lastSessionEverDegraded = false
        self.lastDroppedFrames = 0
        self.dominantCause = .notDegraded
        self.lastWriteError = nil
        // Reset all critical-signal state — structural invariant: no stale carry-over across sessions.
        self.cameraLossView = nil
        self.windowedHardView = nil
        self.sessionMaxSeverityLatch = nil
        self.fpsDetector = FpsCollapseDetector()
        self.sustainedDetector = SustainedDropDetector()
        self.lastMonotonicElapsedSeconds = 0
        self.lastLiveNotificationElapsedSeconds = nil
        self.hardLiveNotificationPosted = false
        self.softLiveNotificationPosted = false
        // Disk-space state (spec #88): clear the prior session's warning/stop attribution and
        // reset the monitor's rolling state so a stale in-flight refresh from that session cannot
        // contaminate this one (AC-1 clear).
        self.diskWarning = nil
        self.stoppedDueToLowSpace = false
        self.pendingDiskStopReason = nil
        // The idle headline (T-7) is meaningless once a session exists — the tick loop's own
        // verdict/warning take over; clearing avoids a stale idle number surviving into a future
        // idle re-appear before the next `refreshIdleDiskEstimate` call lands.
        self.idleDiskEstimate = nil
        self.diskSpaceMonitor.reset()
        self.phase = .recording

        self.startStateSubscription(session)
        self.startRevocationSubscription(session)
        self.startTickLoop(session)

        // Window choreography (AC-3): hide main window on start; recording window opens
        // on demand from the menu bar («Открыть окно записи», #242 — menu-bar-first).
        // Start notifier fires below to confirm the recording has begun.
        self.dismissMainWindow()
        self.notifier.notifyRecordingStarted()
        // Keep the display/system awake for the whole recording (#87) — released in the single
        // stop-teardown path below.
        self.sleepPreventer.beginPreventingSleep()
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
                    // Critical signal (soft): the screen keeps recording, so this is `cameraAndScreen`.
                    // `.allVideoSourcesLost` (below) is the hard `cameraOnly` counterpart.
                    self.handleCameraLoss(scope: .cameraAndScreen)

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
                    // Critical signal (hard, terminal): the camera was the only video source; its loss
                    // stops the session. Latch the indicator + post the timeSensitive live notification
                    // BEFORE stop() tears the loop down, so the signal reaches the user.
                    self.handleCameraLoss(scope: .cameraOnly)
                    await self.stop()
                }
            }
        }
    }

    /// One ~1 Hz loop: bumps `elapsed` from `startedAt`, polls the session's drop health, steps
    /// the critical detectors on the MONOTONIC session clock, and drives the disk-space monitor
    /// (spec #88, AC-2). All readouts tick at the same cadence, so they share one task (one cancel
    /// point) — no new timers are introduced for either signal.
    ///
    /// Two clocks, deliberately distinct (spec §P2):
    ///  - `Date()` drives `elapsed`, the human-facing UI timer ONLY.
    ///  - `session.currentSessionElapsedSeconds()` (host-time since session T0) drives the detector
    ///    windows + dedupe. It shares `CameraRateSnapshot.monotonicStampSeconds`' frame, so the
    ///    detectors' staleness gate and warmup skip stay correct. `Date()` must never feed the windows.
    ///
    /// ### Disk-space integration (AC-2)
    /// `monitor.tickRefresh` is NOT awaited — the monitor throttles the actual XPC read to
    /// `readEvery` and single-flights it internally, so a slow provider read never delays this
    /// loop's elapsed/drops/critical-detector readout. `monitor.currentVerdict` is then read
    /// synchronously (the cached value from the last completed refresh) and acted on by
    /// `applyDiskVerdict` — ALL disk-space DECISIONS (warning post, critical auto-stop) live here on
    /// the MainActor-serial tick, never inside the monitor's own refresh task.
    private func startTickLoop(_ session: any RecordingControlling) {
        self.tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let startedAt = self.startedAt {
                    self.elapsed = Int(Date().timeIntervalSince(startedAt))
                }
                let health = await session.currentDrops()
                self.drops = health.counters
                let monotonicElapsed = await session.currentSessionElapsedSeconds()
                let rates = await session.currentRates()
                self.lastMonotonicElapsedSeconds = monotonicElapsed
                self.stepCriticalDetectors(
                    isDegraded: self.recordingState == .degraded,
                    rates: rates,
                    monotonicElapsed: monotonicElapsed
                )

                self.diskSpaceMonitor.tickRefresh(outputURL: session.sessionDirectory)
                if self.applyDiskVerdict(self.diskSpaceMonitor.currentVerdict) == .stop {
                    break
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Steps both pure detectors for one tick and folds their verdicts into the two critical values
    /// (`liveCriticalView` de-escalating, `sessionMaxSeverityLatch` climbing) plus the live-notification
    /// dispatch (critical-recording-signals, T-C.1/T-C.2).
    ///
    /// Both windowed-hard incidents (`sustainedDrops`, `fpsCollapse`) DE-ESCALATE: when neither fires
    /// this tick the live view returns to `nil`. A camera-loss view (either scope) is owned by the
    /// revocation path and PRESERVED here — camera loss is one-shot (the camera does not return), so a
    /// quiet detector tick must not wipe it (otherwise the soft a11y-label would flicker off; spec
    /// AC-1). Only a windowed-hard view is subject to de-escalation. The session latch only climbs.
    ///
    /// `internal` (not `private`) so L2 tests drive the across-tick state machine by direct
    /// synchronous calls — the only deterministic way to exercise de-escalation / cap / override
    /// (the live 1 Hz loop's `Task.sleep` is non-deterministic, and the soft→hard override path is
    /// unreachable through the revocation streams, which only deliver the terminal `cameraOnly`).
    func stepCriticalDetectors(
        isDegraded: Bool,
        rates: CameraRateSnapshot?,
        monotonicElapsed: Double
    ) {
        let config = RecordingConfiguration.mvpDefault

        let sustained = self.sustainedDetector.evaluateLive(
            isDegraded: isDegraded,
            elapsedSeconds: monotonicElapsed,
            config: config
        )
        self.sustainedDetector = sustained.next

        var fpsCollapsed = false
        if let rates {
            let sample = FpsCollapseSample(
                deliveredFps: rates.deliveredFps,
                dropOverflowRate: rates.dropOverflowRate,
                gapMsMax: rates.gapMsMax,
                sampleElapsedSeconds: rates.monotonicStampSeconds
            )
            let step = self.fpsDetector.step(sample: sample, elapsedSeconds: monotonicElapsed, config: config)
            self.fpsDetector = step.next
            fpsCollapsed = step.verdict.collapsed
        }

        // Pick the windowed-hard incident firing this tick (either qualifies as `.hard`). When both
        // fire, `sustainedDrops` is reported first — they share a tier, so the choice is cosmetic.
        let firedIncident: CriticalIncident? = switch (sustained.fired, fpsCollapsed) {
        case (true, _): .sustainedDrops
        case (false, true): .fpsCollapse
        case (false, false): nil
        }

        // De-escalation: the windowed-hard view tracks THIS tick's verdict (incident or nil) — a
        // passed drop-storm clears it. The sticky camera-loss view is untouched here (owned by the
        // revocation path). `liveCriticalView` derives the displayed incident from both.
        self.windowedHardView = firedIncident

        if let firedIncident {
            self.escalateLatch(to: firedIncident.severity)
            self.dispatchLiveNotification(firedIncident, monotonicElapsed: monotonicElapsed)
        }
    }

    /// Raises `sessionMaxSeverityLatch` to `severity` if it is higher (or first). `hard > soft`; the
    /// latch only ever climbs — it feeds the post-stop branch, never the live indicator.
    private func escalateLatch(to severity: CriticalSeverity) {
        switch (self.sessionMaxSeverityLatch, severity) {
        case (nil, _), (.soft, .hard):
            self.sessionMaxSeverityLatch = severity

        case (.soft, .soft), (.hard, _):
            break // already at or above the incoming tier
        }
    }

    /// Dispatches a LIVE critical notification under the dedupe + session-cap policy (T-C.4 / AC-9 /
    /// AC-3(б)):
    ///  - SESSION CAP: each tier (`hard` / `soft`) posts at most ONCE per session. A recurrent
    ///    windowed-hard after de-escalation updates the indicator (caller) but posts no second banner.
    ///  - PER-WINDOW SUPPRESS: within `criticalNotificationDedupeSeconds` of the last dispatch, a
    ///    same-or-lower tier is suppressed.
    ///  - SEVERITY OVERRIDE: a higher tier always breaks through suppression (soft shown → hard posts).
    ///
    /// The notifier handles the per-tier interruption level; the coordinator owns only the gating.
    /// `internal` so L2 tests exercise the override / cap paths by direct call (see
    /// `stepCriticalDetectors` rationale).
    func dispatchLiveNotification(_ incident: CriticalIncident, monotonicElapsed: Double) {
        let severity = incident.severity

        // Session cap: this tier already posted once → indicator-only, no second banner.
        if severity == .hard, self.hardLiveNotificationPosted {
            return
        }
        if severity == .soft, self.softLiveNotificationPosted {
            return
        }

        // Per-window suppress + severity-override: inside the dedupe window, suppress unless THIS tier
        // is strictly higher than what the cap shows was already posted (override). A hard breaks
        // through a window opened by a soft; a soft inside any window is suppressed.
        let dedupeWindow = RecordingConfiguration.mvpDefault.criticalNotificationDedupeSeconds
        let insideWindow = self.lastLiveNotificationElapsedSeconds.map { monotonicElapsed - $0 < dedupeWindow }
            ?? false
        let isHardOverridingSoft = severity == .hard && !self.hardLiveNotificationPosted
        if insideWindow, !isHardOverridingSoft {
            return
        }

        self.notifier.notifyCriticalIncident(incident)
        self.lastLiveNotificationElapsedSeconds = monotonicElapsed
        switch severity {
        case .hard:
            self.hardLiveNotificationPosted = true

        case .soft:
            self.softLiveNotificationPosted = true
        }
    }

    /// Maps a camera-loss revocation to a `CriticalIncident` and drives BOTH critical values
    /// (T-C.3 / AC-1 / AC-2). `cameraOnly` (hard, terminal) latches the live view until stop;
    /// `cameraAndScreen` (soft, transient) surfaces briefly without latching. Both climb the session
    /// latch and dispatch a live notification under the same dedupe/cap policy. `internal` so AC-1/AC-2
    /// L2 tests can drive scope mapping directly (the soft scope is unreachable through the streams).
    func handleCameraLoss(scope: CriticalIncidentScope) {
        let incident = CriticalIncident.cameraLost(scope: scope)
        // Sticky camera-loss view (one-shot — the camera does not return). A terminal `cameraOnly`
        // (hard) overrides a prior soft `cameraAndScreen`; never the reverse (severity only climbs in
        // the displayed view via `liveCriticalView`'s derivation, and the camera lifecycle is one-way).
        if self.cameraLossView?.severity != .hard {
            self.cameraLossView = incident
        }
        self.escalateLatch(to: incident.severity)
        self.dispatchLiveNotification(incident, monotonicElapsed: self.lastMonotonicElapsedSeconds)
    }

    /// Emits the post-stop summary notification keyed by the session's final max severity (T-C.4 /
    /// AC-13 / AC-8). Folds the post-stop drop-rate criterion (`evaluatePostStop`, AC-4) into the live
    /// latch, then:
    ///  - any hard → `notifyPostStopSummary(.hard)`;
    ///  - soft only → `.soft`;
    ///  - none → nothing (minor drops stay disk-only, #246 — and this NEVER forces the window open).
    ///
    /// Fire-and-forget only: it must not touch `hasPendingAlert` or the window choreography (#246 /
    /// T0.1 — the existing degraded path is log-only + reveal, no UI warning surface; the critical
    /// post-stop is a separate, additive path that preserves that behavior).
    private func finalizePostStopSummary(result: RecordingResult, sessionDir: URL, sessionStartDate: Date) {
        // Post-stop drop-rate (AC-4): normalized intensity over the monotonic session duration. Uses
        // encoderBackpressureDrops — the same reason that drives `degraded` (spec §2 escalation).
        let postStopHard = SustainedDropDetector.evaluatePostStop(
            totalDrops: result.drops.encoderBackpressureDrops,
            durationSeconds: self.lastMonotonicElapsedSeconds,
            config: RecordingConfiguration.mvpDefault
        )
        if postStopHard {
            self.escalateLatch(to: .hard)
        }

        guard let severity = self.sessionMaxSeverityLatch else {
            // No critical incident this session → disk-only (#246), no post-stop notification.
            return
        }
        // Reconstruct the report file URL so the tap action reveals it in Finder (AC-12). The report
        // shares the session-start timestamp and lives inside the session folder (`RecordingOutput`).
        // `URL(filePath:relativeTo:)` REPLACES the base's last path component when the base is not
        // flagged as a directory (e.g. `/tmp/session` → `/tmp/<report>`, dropping the session folder).
        // Re-flag the base as a directory first so the report always resolves as a child, yielding the
        // identical on-disk path that `RecordingOutput.writeReport(_:in:timestamp:)` produces at write
        // time. Real session dirs are already directory-flagged (`OutputDirectoryNaming`); this guards
        // any caller that passes a non-flagged URL.
        let sessionDirectory = sessionDir.hasDirectoryPath
            ? sessionDir
            : URL(filePath: sessionDir.path(percentEncoded: false), directoryHint: .isDirectory)
        let reportURL = URL(
            filePath: RecordingOutput.reportFileName(timestamp: sessionStartDate),
            relativeTo: sessionDirectory
        )
        self.notifier.notifyPostStopSummary(severity: severity, reportURL: reportURL)
    }

    // MARK: - Disk-space monitoring (spec #88, AC-2/AC-3/AC-4/AC-11)

    /// Idle pre-flight disk-space read (AC-1/AC-3, T-7): computes the "≈ N мин" headline plus the
    /// idle disk verdict from ONE fresh snapshot, before any recording session exists. THIS
    /// coordinator owns `diskSpaceMonitor` (and thus the provider) and reads off-main —
    /// `MainViewModel` only displays `idleDiskEstimate`, it never reads disk state itself.
    ///
    /// Cadence (spec #88 T-7): called once when the main screen appears
    /// (`MainViewModel.refreshIdleDiskEstimate()`, via `MainView`'s `.task`) and again when a new
    /// recording is initiated (`MainViewModel.record()`) — there is no idle polling; staleness
    /// between those two points is accepted (plan.md "Idle-оценка владелец/каденция").
    ///
    /// A no-op while a recording is active: once a session exists, the tick loop
    /// (`applyDiskVerdict`) is the sole owner of `diskWarning` and auto-stop decisions.
    func refreshIdleDiskEstimate(plan: ResolvedRecordingPlan, config: RecordingConfiguration) async {
        guard self.phase != .recording else { return }
        let snapshot = await self.diskSpaceMonitor.idleEstimate(
            outputURL: config.baseOutputDirectory,
            plan: plan
        )
        self.idleDiskEstimate = snapshot.estimate
        switch snapshot.verdict {
        case .none:
            self.diskWarning = nil

        case let .warning(reason):
            self.diskWarning = reason

        case let .critical(reason):
            // No session exists to auto-stop (AC-4 doesn't apply at idle) and Start is NOT
            // blocked (Open Question → option A) — still surface the same warning/badge the
            // in-recording path uses (AC-3) so a critically-low volume is visible before Record.
            self.diskWarning = reason.idleWarningReason
        }
    }

    /// What the tick loop must do after applying one disk-space verdict.
    private enum DiskVerdictAction: Equatable {
        /// Recording continues (verdict is `.none` or `.warning`).
        case `continue`
        /// Verdict is `.critical` — the tick loop must break; a stop has been handed off.
        case stop
    }

    /// Applies the disk-space monitor's cached verdict on one tick — the sole place disk-space
    /// DECISIONS are made (the monitor's own refresh task only updates the cache).
    private func applyDiskVerdict(_ verdict: DiskVerdict) -> DiskVerdictAction {
        switch verdict {
        case .none:
            // De-escalation (AC-11): the monitor/estimator (T-3/T-4) only returns `.none` once its
            // own hysteresis + debounce has decided the metric recovered — simply mirror that here.
            if self.diskWarning != nil {
                self.diskWarning = nil
            }
            return .continue

        case let .warning(reason):
            // Equatable-guard (AC-12): post once per NEW crossing, not on every tick the warning
            // stays active.
            if self.diskWarning != reason {
                self.diskWarning = reason
                self.diskWarningNotifier.notifyLowSpaceWarning(reason: reason)
            }
            return .continue

        case let .critical(reason):
            // AC-4/AC-8: hand off via an UN-AWAITED Task — inline `await self.stop()` here would
            // self-deadlock: `performStopTeardown` awaits `tick?.value` (:774), and this tick IS
            // that same task. Precedent for the un-awaited form: `handleHotKey()` (:956).
            coordinatorLogger.error("Disk-space critical verdict — auto-stopping recording (AC-4)")
            self.diskWarning = nil
            self.pendingDiskStopReason = reason
            Task { await self.stop() }
            return .stop
        }
    }

    // MARK: - Stop (AC-9) — funnel for all three stop paths

    /// Stops the active recording. Funnel for ALL stop paths — button / hotkey / menu (AC-9),
    /// `.allVideoSourcesLost` auto-stop, and `finalizeForTermination` (#243). Every path awaits the
    /// SAME memoized teardown handle (`stopTask`), so the teardown (reveal, warning, phase
    /// transition) runs exactly once even under concurrent calls, and a later caller — including
    /// app termination — waits for whatever teardown is ALREADY in flight rather than starting a
    /// fresh guarded call that would no-op and return early (#243 defect 1). The underlying
    /// `RecordingSession.stop()` is itself memoized, so `session.stop()` is invoked exactly once.
    func stop() async {
        // Fix #3: if the user presses stop/hotkey during the consent wait, cancel activation so
        // start() reverts promptly and silently (no error alert).
        if self.isStarting {
            self.cancelActivation()
            return
        }
        await self.sharedStopTask()?.value
    }

    /// Returns the single in-flight teardown handle, starting it on first entry.
    ///
    /// Memoization is the funnel: the first caller flips `isStopping`/`stopTask` synchronously on
    /// the MainActor (before any `await`) and spawns the teardown; every concurrent caller sees the
    /// non-nil `stopTask` and awaits the SAME handle. Returns `nil` when there is nothing to stop
    /// (not recording, or already fully stopped) so callers await nothing.
    private func sharedStopTask() -> Task<Void, Never>? {
        if let stopTask {
            return stopTask
        }
        guard self.phase == .recording, !self.isStopping, let session = self.session else { return nil }
        self.isStopping = true
        let task = Task { await self.performStopTeardown(session) }
        self.stopTask = task
        return task
    }

    // swiftlint:disable function_body_length
    /// The one teardown body, run exactly once via the memoized `stopTask`. Clears the
    /// `isStopping`/`stopTask` pair at the end so a subsequent recording starts clean.
    private func performStopTeardown(_ session: any RecordingControlling) async {
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

        // Capture sessionDirectory + start date before the await — nonisolated lets, safe to read
        // synchronously. The start date derives the report file name for the actionable post-stop
        // notification (AC-12).
        let sessionDir = session.sessionDirectory
        let sessionStartDate = session.sessionStartDate

        let result = await session.stop()

        self.lastResult = result
        self.lastSessionDirectory = sessionDir
        self.drops = result.drops
        self.lastSessionEverDegraded = result.sessionEverDegraded
        self.lastDroppedFrames = result.drops.encoderBackpressureDrops
        self.dominantCause = result.dominantCause
        self.lastWriteError = result.writeFailureReason
        // Disk-stop attribution (AC-9): `pendingDiskStopReason` is set by the tick loop only when
        // THIS teardown was triggered by a `.critical` disk-space verdict — every other stop path
        // (button/hotkey/menu, `.allVideoSourcesLost`, termination) leaves it `nil`. Consume it
        // exactly once here; it must not survive into the next session's stop.
        let diskStopReason = self.pendingDiskStopReason
        self.pendingDiskStopReason = nil
        self.stoppedDueToLowSpace = diskStopReason != nil
        if let diskStopReason {
            self.diskWarningNotifier.notifyAutoStopped(
                reason: diskStopReason,
                filesSaved: DiskSpaceSavedFiles(screenURL: result.screen?.url, cameraURL: result.camera?.url)
            )
        }
        self.session = nil
        self.startedAt = nil
        // End the sleep-prevention hold started in activateRecording() — the sole release point,
        // covering both a user-initiated stop() and finalizeForTermination()'s teardown.
        self.sleepPreventer.endPreventingSleep()

        // Post-stop critical summary (T-C.4): fold the post-stop drop-rate criterion into the session
        // max severity, then notify by tier. AC-4: a session with high cumulative drop intensity that
        // never held degraded continuously still qualifies as hard post-stop — the live latch alone
        // would miss it, so `evaluatePostStop` runs here against the result.
        self.finalizePostStopSummary(result: result, sessionDir: sessionDir, sessionStartDate: sessionStartDate)

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

        // Clear the isStopping/stopTask pair in lockstep now that teardown is complete: the next
        // recording starts with a clean handle, and any late duplicate stop() call finds phase !=
        // .recording and no-ops. Cleared AFTER the terminal phase is set so a concurrent caller
        // awaiting this same handle observes the fully-torn-down state on resume.
        self.isStopping = false
        self.stopTask = nil
        // Recording-active gate OFF only now — after the terminal phase is set above — so the
        // gate stays true across the entire stop window, false only once fully stopped.
        self.isRecordingActive = false
        // Session directory name (not full path) is safe to log — no home path (issue #188).
        let fileCount = result.outputURLs.count
        let originDescription = String(describing: self.origin)
        coordinatorLogger.info(
            "Recording stopped — files=\(fileCount) dir=\(sessionDir.lastPathComponent) origin=\(originDescription)"
        )
    }

    // swiftlint:enable function_body_length

    // MARK: - Termination (#243)

    // swiftlint:disable no_magic_numbers
    // The literal below is the definition site (mirrors CameraPreviewTimeout's threshold constants).
    /// Default bound for `finalizeForTermination`'s wait.
    ///
    /// A few seconds above the ~4s `RecordingConfiguration.mvpDefault.movieFragmentInterval` —
    /// enough slack for the teardown's own awaited work (drop-poll tick, session finish) to finish
    /// first in the common case, while still bounding the worst case: `finalizeForTermination`
    /// ABANDONS the wait at this deadline (it does not await the teardown after timeout), so app
    /// termination returns within ~this bound even when the teardown is genuinely stuck.
    static let defaultTerminationFinalizationTimeout: Duration = .seconds(5)
    // swiftlint:enable no_magic_numbers

    /// Best-effort finalization for graceful app termination (Cmd-Q / Dock Quit / `NSApp.terminate`).
    ///
    /// Before #242 (menu-bar-first recording) the recording window's `.onDisappear` called
    /// `stop()`, so quitting mid-recording always ran the normal teardown. That path was removed
    /// when the window stopped being the only way to see a recording, leaving a regression:
    /// terminating the app during an active recording fell straight through to
    /// `movieFragmentInterval` fragment-recovery (AC-10) — the files are only *recoverable* from
    /// fragment headers, never cleanly finalized. This awaits the shared teardown handle so
    /// termination gets the same finalize/reveal teardown as the button/hotkey/menu paths — and,
    /// crucially, awaits whatever teardown is ALREADY in flight (a stop already triggered by the
    /// user, the hotkey, or `.allVideoSourcesLost`) rather than a fresh guarded call that would
    /// no-op and let the process terminate mid-teardown (#243 defect 1).
    ///
    /// No-op when idle — `applicationShouldTerminate` calls this unconditionally, and only the
    /// active-recording case has anything to await. During the consent-wait window it cancels
    /// activation (like `stop()`) and returns: no committed recording exists yet to finalize.
    ///
    /// ### Real abandon-at-deadline (#243 defect 2)
    /// The teardown eventually calls `RecordingSession.stop()`, whose `performStop()` runs in an
    /// unstructured, non-cancellable `Task` (VideoToolbox flush / `AVAssetWriter.finishWriting()`
    /// can block). A `withTaskGroup` + `cancelAll()` would NOT bound this: the group drains all
    /// children on scope exit and the teardown child never observes cancellation, so termination
    /// would hang exactly when the bound is needed. Instead this races the teardown handle's
    /// completion against `Task.sleep(timeout)` via a `CheckedContinuation` resumed EXACTLY ONCE by
    /// whichever finishes first (`TerminationGate`). On timeout it returns WITHOUT awaiting the
    /// teardown Task — the teardown keeps running best-effort (it may still finish cleanly before
    /// the process dies), and the on-disk floor is the ~4s `movieFragmentInterval` fragment
    /// recovery (AC-10), which is playable, not truncated. `finalizeForTermination` therefore always
    /// returns within ~`timeout`, so the caller's `NSApp.reply(toApplicationShouldTerminate: true)`
    /// fires exactly once and quit proceeds bounded.
    func finalizeForTermination(timeout: Duration = defaultTerminationFinalizationTimeout) async {
        // Consent-wait window: cancel activation so start() reverts promptly. No committed recording
        // to finalize (files never began) — mirrors stop()'s isStarting handling.
        if self.isStarting {
            self.cancelActivation()
            return
        }
        guard self.isRecordingActive, let teardown = self.sharedStopTask() else { return }
        coordinatorLogger.notice("App termination requested during an active recording — finalizing")
        await Self.awaitOrAbandon(teardown, timeout: timeout)
    }

    /// Returns when EITHER `teardown` completes OR `timeout` elapses — whichever is first — without
    /// draining the loser. On the timeout path the teardown Task is left running (best-effort); we
    /// never `await teardown.value` after the deadline, which is what would re-couple to a stuck,
    /// non-cancellable teardown and hang (#243 defect 2).
    ///
    /// The `CheckedContinuation` is resumed exactly once, guarded by `TerminationGate`. Both waiter
    /// tasks inherit `@MainActor`, so the gate's check-and-set is serialized — no data race, no
    /// double-resume. The completion waiter, if it loses, resolves harmlessly later (its `resume`
    /// is a no-op) or dies with the process; the deadline task is cancelled when completion wins so
    /// no orphaned sleep lingers.
    private static func awaitOrAbandon(_ teardown: Task<Void, Never>, timeout: Duration) async {
        let gate = TerminationGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let deadlineTask = Task {
                try? await Task.sleep(for: timeout)
                if gate.resume(continuation) {
                    coordinatorLogger.error(
                        // swiftlint:disable:next line_length
                        "Termination finalization timed out — abandoning teardown; quit proceeds (fragment-recovery floor)"
                    )
                }
            }
            // Completion waiter — leaks harmlessly if the deadline wins (its resume no-ops).
            Task {
                await teardown.value
                if gate.resume(continuation) {
                    deadlineTask.cancel()
                }
            }
        }
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

    // MARK: - Dock reopen (#272)

    /// Handles a Dock-icon reopen (macOS `applicationShouldHandleReopen`). While recording,
    /// focus the recording window and suppress SwiftUI's default main-window reopen; otherwise
    /// let the default proceed. Returns whether the system should perform its default handling.
    func handleReopen() -> Bool {
        guard self.phase == .recording else { return true }
        self.openRecordingWindow()
        return false
    }
}

// MARK: - TerminationGate

/// One-shot resume guard for `finalizeForTermination`'s abandon-at-deadline race.
///
/// The teardown-completion waiter and the deadline waiter both try to resume the SAME
/// `CheckedContinuation`; exactly one must win. `@MainActor` isolation serializes the check-and-set
/// (both waiters inherit MainActor from the enclosing method), so the plain `Bool` needs no locking
/// and a double-resume — which would trap — cannot happen.
@MainActor
private final class TerminationGate {
    private var resumed = false

    /// Resumes the continuation iff it has not already been resumed. Returns `true` when THIS call
    /// performed the resume (the caller "won" the race), `false` when the other waiter already did.
    func resume(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        guard !self.resumed else { return false }
        self.resumed = true
        continuation.resume()
        return true
    }
}
