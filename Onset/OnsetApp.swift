import AppKit
import os
import SwiftUI

// MARK: - Logger

nonisolated private let appLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "OnsetApp"
)

// MARK: - Window IDs

/// Stable scene identifiers used by `openWindow` / `dismissWindow`.
/// Internal so `MenuBarMenu` can open windows without re-declaring the constants.
enum WindowID {
    static let main = "onboarding"
    static let recording = "recording"
}

// MARK: - Window defaults

/// Fixed window dimensions shared by `OnsetApp` scenes and the views they host.
///
/// Views use these constants to set an exact `frame(width:height:)` that matches
/// `.windowResizability(.contentSize)` — ensuring the window size is locked to the
/// content size with no flexible range for the user to drag.
enum WindowDefaults {
    static let width: CGFloat = 460
    /// Tall enough that `MainView.mainContent`'s `ScrollView` does not need to actually
    /// scroll in the worst realistic content state: all sections, the camera live preview
    /// (#267), both device-loss notice rows (#261), and a footer disabled-reason line
    /// (#316). Measured 648pt via `NSHostingView.fittingSize` on that layout; the
    /// `ScrollView` itself stays in place as a safety net for larger Dynamic Type, not
    /// the default state.
    static let height: CGFloat = 660
    static let recordingWidth: CGFloat = 370
    static let recordingHeight: CGFloat = 420
}

// MARK: - OnsetApp

@main
struct OnsetApp: App {
    // MARK: - App delegate

    /// Handles graceful termination (#243) — see `AppDelegate`. Wired to the coordinator from
    /// `WindowActionsBridge.onAppear`, mirroring how the bridge wires the hotkey monitor.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // MARK: - Composition root

    /// The single `PermissionsService` instance shared across all scenes.
    ///
    /// Created at app-init time so statuses are snapshotted immediately and routing
    /// decisions on the first render are based on real data.
    ///
    /// `PermissionsService.init` only performs non-prompting TCC status reads
    /// (`CGPreflightScreenCaptureAccess`, `AVCaptureDevice.authorizationStatus`) — no
    /// observers, timers, or async work — so it is safe to construct under test as well.
    @State private var permissionsService = PermissionsService(
        screenPermission: ScreenRecordingPermission(),
        capturePermission: CaptureDevicePermission(),
        relauncher: AppRelauncher()
    )

    /// The single recording-lifecycle owner, shared by all recording-aware surfaces (#36/#37/#38).
    /// Window actions are wired into it from `WindowActionsBridge` once the env actions exist.
    @State private var coordinator = RecordingCoordinator()

    /// The single `@Observable` settings model — in-memory source of truth for app-wide settings.
    ///
    /// Owned here at the composition root and injected into every consumer (`RootView` →
    /// `MainViewModel`, `MenuBarLabel`) so a toggle in the Settings window propagates live.
    /// Under XCTest an `InMemorySettingsStore` is injected: this `@State` initial value is
    /// evaluated even though the windows render `EmptyView`, and a `UserDefaults.standard`-backed
    /// store would trap (see `UserDefaultsSettingsStore` / `OnsetTests/CLAUDE.md`).
    @State private var appSettings = AppSettings(
        store: isRunningUnderXCTest ? InMemorySettingsStore() as any SettingsPersisting : UserDefaultsSettingsStore()
    )

    /// System-wide hotkey monitor (#67 / AC-9 third stop path). Created at app-init time;
    /// registered once from `WindowActionsBridge.onAppear` after the coordinator is wired.
    /// Suppressed under XCTest — a test host must not grab the system-wide ⌘⌥⌃R shortcut
    /// (would fight any other test run on the same machine and could accidentally stop a
    /// real recording if the key is pressed during a test session).
    @State private var hotKeyMonitor = GlobalHotKeyMonitor()

    /// Coordinator for the diagnostic export flow (#164): collect OS logs → NSSavePanel → reveal.
    /// Shared by `MenuBarMenu`; created once at app-init time (lightweight, no I/O at init).
    @State private var diagnosticsCoordinator = DiagnosticsSaveCoordinator()

    var body: some Scene {
        Window("Onset", id: WindowID.main) {
            // Under XCTest the window is empty (no RootView, no onboarding flow, no
            // PermissionsService UI lifecycle). This prevents multiple app instances from
            // accumulating across test runs and popping competing onboarding windows that
            // fight over screen/camera TCC permissions with the L5 live-capture tests.
            //
            // TCC grants are held at the process / bundle-ID level, not by individual
            // windows, so suppressing the view here does NOT remove screen-recording or
            // camera permission from the test-host process — L5 hardware-capture tests
            // continue to receive their grants unchanged.
            if isRunningUnderXCTest {
                EmptyView()
            } else {
                RootView(
                    permissionsService: self.permissionsService,
                    coordinator: self.coordinator,
                    appSettings: self.appSettings,
                    hasPostScreenGrantArg: CommandLine.arguments.contains(AppRelauncher.postScreenGrantArg)
                )
                // Capture the env window actions into the coordinator (a plain class cannot read
                // @Environment(\.openWindow) itself). Also registers the system-wide hotkey (#67).
                .background(WindowActionsBridge(
                        coordinator: self.coordinator,
                        hotKeyMonitor: self.hotKeyMonitor,
                        appDelegate: self.appDelegate
                    ))
            }
        }
        // Fixed-size window that wraps the content — prevents user resizing.
        .windowResizability(.contentSize)
        .defaultSize(width: WindowDefaults.width, height: WindowDefaults.height)
        // Explicitly open the main window at launch; a regular app focuses it automatically.
        .defaultLaunchBehavior(.presented)

        // The recording-in-progress window (#37). Suppressed under XCTest for the same reason as
        // the main window.
        Window("Onset — запись", id: WindowID.recording) {
            if isRunningUnderXCTest {
                EmptyView()
            } else {
                RecordingView(coordinator: self.coordinator)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
        // Do NOT auto-open at launch — only the main window presents on launch; the recording window
        // opens on Record (AC-3). Without this the second Window scene would also pop at startup.
        .defaultLaunchBehavior(.suppressed)

        // Menu bar item (#38). Full 3-state label and context menu.
        // Suppressed under XCTest so test hosts do not accumulate competing status items.
        MenuBarExtra(isInserted: .constant(!isRunningUnderXCTest)) {
            MenuBarMenu(
                coordinator: self.coordinator,
                diagnosticsCoordinator: self.diagnosticsCoordinator,
                appSettings: self.appSettings
            )
        } label: {
            MenuBarLabel(coordinator: self.coordinator, appSettings: self.appSettings)
        }

        // Settings (⌘,) window. The scene is lazy and not auto-presented; it is reached via ⌘,
        // (with a focused window) or the `SettingsLink` in `MenuBarMenu`. Suppressed under XCTest
        // for the same reason as the sibling scenes — a test host must not open settings windows.
        Settings {
            if isRunningUnderXCTest {
                EmptyView()
            } else {
                SettingsView(appSettings: self.appSettings, coordinator: self.coordinator)
            }
        }
    }
}

// MARK: - WindowActionsBridge

/// Invisible helper that reads the SwiftUI environment window actions and installs them as closures
/// on the coordinator. A plain `@Observable` class cannot read `@Environment(\.openWindow)`; this
/// bridge runs inside a `View` where the actions exist and forwards them once on appear.
///
/// Also registers the global hotkey (#67) after the coordinator is wired, so `handleHotKey()`
/// has a fully-bound coordinator when the hotkey fires. Suppressed under XCTest via the
/// `isRunningUnderXCTest` gate on the enclosing `Window` view — the bridge never mounts under
/// test, so `hotKeyMonitor.register` is never called.
private struct WindowActionsBridge: View {
    let coordinator: RecordingCoordinator
    let hotKeyMonitor: GlobalHotKeyMonitor
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                self.coordinator.bindWindowActions(
                    openRecordingWindow: {
                        self.openWindow(id: WindowID.recording)
                        AppActivation.bringToFront()
                    },
                    dismissMainWindow: { self.dismissWindow(id: WindowID.main) },
                    dismissRecordingWindow: { self.dismissWindow(id: WindowID.recording) },
                    openMainWindow: {
                        self.openWindow(id: WindowID.main)
                        AppActivation.bringToFront()
                    }
                )
                self.coordinator.enterMain()

                // Wire the coordinator into the app delegate so applicationShouldTerminate(_:)
                // can finalize an active recording on Cmd-Q / Dock Quit (#243). A plain
                // NSApplicationDelegate has no SwiftUI environment access of its own.
                self.appDelegate.coordinator = self.coordinator

                // Register the system-wide hotkey after the coordinator is fully wired
                // (#67 / AC-9). The monitor's register() is idempotent; onAppear may fire
                // more than once on scene re-attachment, so the guard inside register() is
                // the primary de-duplication.
                // Belt-and-suspenders: the monitor is also never instantiated under XCTest
                // because this bridge only mounts when isRunningUnderXCTest is false
                // (the enclosing `Window` body shows EmptyView instead).
                // Capture only the coordinator (a reference type that does not point back
                // to the monitor), breaking the bridge-struct → hotKeyMonitor cycle so
                // the monitor's deinit/unregister teardown path remains reachable.
                self.hotKeyMonitor.register { [coordinator = self.coordinator] in
                    coordinator.handleHotKey()
                }
            }
    }
}

// MARK: - AppDelegate

/// Finalizes an active recording on graceful app termination (#243).
///
/// `NSApplication` calls `applicationShouldTerminate(_:)` synchronously on Cmd-Q, Dock Quit, and
/// `NSApp.terminate(_:)`. Without this delegate, quitting mid-recording falls straight through to
/// `movieFragmentInterval` fragment-recovery — the output files are only *recoverable*, never
/// cleanly finalized. `coordinator.finalizeForTermination()` routes through the normal `stop()`
/// funnel instead (bounded — see its doc comment), so termination gets the same finalize/reveal
/// teardown as the button/hotkey/menu stop paths.
///
/// `coordinator` is wired in from `WindowActionsBridge.onAppear` — a plain `NSObject` delegate has
/// no SwiftUI environment access of its own, so it cannot read the composition-root `@State`
/// directly (mirrors how the bridge wires `GlobalHotKeyMonitor`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once at startup by `WindowActionsBridge`. `nil` only in the brief window before that
    /// wiring runs, in which case termination proceeds immediately — no recording can have
    /// started yet, so there is nothing to finalize.
    var coordinator: RecordingCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.isRecordingActive else { return .terminateNow }
        appLogger.notice("Termination requested during an active recording — finalizing before quit")
        Task {
            await coordinator.finalizeForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - AppActivation

/// Brings the app to the front when a window is reopened from the menu bar.
///
/// `NSApp.activate()` suffices for a regular app — no activation-policy switching needed.
/// Skipped under XCTest: test hosts must not steal focus.
/// Internal so `MenuBarMenu` can call it directly.
enum AppActivation {
    static func bringToFront() {
        guard !isRunningUnderXCTest else { return }
        NSApp.activate()
    }
}

// MARK: - RootView

/// Switches between `.onboarding`, `.allSet`, and `.main` routes.
///
/// Routing is **status-driven** — no persisted "onboarding completed" flag.
/// Revoking a permission in Settings and returning to the app re-evaluates the route
/// because `permissionsService` is `@Observable` and `RootView.body` reads its statuses.
@MainActor
struct RootView: View {
    // MARK: - Dependencies

    let permissionsService: PermissionsService
    let coordinator: RecordingCoordinator

    /// The shared settings model, forwarded into the `MainViewModel` so the record seam and
    /// camera preview read the same instance the Settings window mutates.
    let appSettings: AppSettings

    // MARK: - Transient routing state

    /// Whether the process was launched with `--post-screen-grant`.
    ///
    /// Held in `@State` so it can be cleared when the user acknowledges the allSet screen,
    /// preventing the route from sticking on `.allSet` after the user taps "Перейти к записи".
    @State private var hasPostScreenGrantArg: Bool

    /// `true` when the user explicitly chose to proceed without full permissions
    /// («Позже» / «Продолжить без экрана» / «Записать без звука»).
    ///
    /// Overrides the status-based route so `onProceedToMain` can navigate even when
    /// `allGranted` is false. Reset when `allGranted` becomes `true` (no bypass needed).
    @State private var bypassToMain = false

    // MARK: - View-owned VMs

    @State private var onboardingViewModel: OnboardingViewModel

    /// The main screen view model, created once and owned for the lifetime of `RootView`.
    @State private var mainViewModel: MainViewModel

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init(
        permissionsService: PermissionsService,
        coordinator: RecordingCoordinator,
        appSettings: AppSettings,
        hasPostScreenGrantArg: Bool
    ) {
        self.permissionsService = permissionsService
        self.coordinator = coordinator
        self.appSettings = appSettings
        _hasPostScreenGrantArg = State(initialValue: hasPostScreenGrantArg)
        _onboardingViewModel = State(initialValue: OnboardingViewModel(permissions: permissionsService))
        _mainViewModel = State(initialValue: MainViewModel(
            permissions: permissionsService,
            appSettings: appSettings,
            coordinator: coordinator
        ))
    }

    // MARK: - Body

    var body: some View {
        // When the user has all permissions, lift the bypass — routing is clean again.
        let allGrantedNow = self.permissionsService.allGranted
        let effectiveBypass = self.bypassToMain && !allGrantedNow

        let route = effectiveBypass
            ? Route.main
            : AppRouter.route(
                allGranted: allGrantedNow,
                hasPostScreenGrantArg: self.hasPostScreenGrantArg,
                screenPreflightGranted: self.permissionsService.screenStatus == .authorized
            )

        Group {
            switch route {
            case .onboarding:
                OnboardingView(viewModel: self.onboardingViewModel) {
                    self.bypassToMain = true
                    appLogger.info("User bypassed onboarding — showing main screen")
                }

            case .allSet:
                AllSetView(permissions: self.permissionsService) {
                    // Clear transient arg so subsequent re-renders use status-based routing.
                    // AppRouter.route(allGranted: true, hasPostScreenGrantArg: false, …) → .main,
                    // so clearing the arg is sufficient — bypassToMain is not needed here and
                    // would cause a regression if the user later revokes a permission.
                    self.hasPostScreenGrantArg = false
                    appLogger.info("AllSet acknowledged — cleared post-screen-grant arg")
                }

            case .main:
                MainView(model: self.mainViewModel) {
                    // Clear the bypass so AppRouter re-evaluates to .onboarding.
                    // This is the escape hatch from the "no permissions" blocked state
                    // that appears when the user tapped «Позже» at 0/3 (AC-7 graceful path).
                    self.bypassToMain = false
                    appLogger.info("Returned from main to onboarding — cleared bypassToMain")
                }
            }
        }
        // One-shot: clear the anti-loop flag on the first render after a post-screen-grant
        // relaunch. Pinned to `hasPostScreenGrantArg` so the task fires once at startup
        // (true), not again after the arg is cleared (false). Moved out of View.init so
        // initializers have no observable side effects.
        .task(id: self.hasPostScreenGrantArg) {
            guard self.hasPostScreenGrantArg else { return }
            AppRelauncher.clearPendingRelaunch()
            appLogger.info("Started with --post-screen-grant; cleared pendingScreenGrantRelaunch flag")
        }
        // Refresh statuses when the app comes to foreground.
        // This is the primary mechanism for detecting revoke-in-Settings (AC-9 / spec).
        .onChange(of: self.scenePhase) { _, newPhase in
            if newPhase == .active {
                self.permissionsService.refresh()
                appLogger.debug(
                    "Scene became active — statuses refreshed; allGranted=\(self.permissionsService.allGranted)"
                )
            }
        }
    }
}
