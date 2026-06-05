import AppKit
import os
import SwiftUI

// MARK: - Logger

nonisolated private let appLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "OnsetApp"
)

// MARK: - Test-mode detection

/// `true` when the process is launched as a test host by XCTest.
///
/// XCTest sets `XCTestConfigurationFilePath` in the environment before executing any test
/// bundle. Detecting it here prevents multiple app instances — each with an onboarding
/// window and live `PermissionsService` UI — from accumulating across test runs and
/// interfering with the L5 live-capture tests that fight over screen/camera permissions.
///
/// Note: screen-recording and camera TCC grants are held by the **process** (bundle ID),
/// not by individual windows. Suppressing the UI scene here does NOT remove those grants
/// from the test-host process, so L5 hardware-capture tests continue to pass.
nonisolated private let isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

// MARK: - Window IDs

/// Stable scene identifiers used by `openWindow` / `dismissWindow`.
/// Internal so `MenuBarMenu` can open windows without re-declaring the constants.
enum WindowID {
    static let main = "onboarding"
    static let recording = "recording"
}

// MARK: - OnsetApp

@main
struct OnsetApp: App {
    // MARK: - Window defaults

    private enum WindowDefaults {
        static let width: CGFloat = 460
        static let height: CGFloat = 560
        static let recordingWidth: CGFloat = 370
        static let recordingHeight: CGFloat = 420
    }

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
                    hasPostScreenGrantArg: CommandLine.arguments.contains(AppRelauncher.postScreenGrantArg)
                )
                // Capture the env window actions into the coordinator (a plain class cannot read
                // @Environment(\.openWindow) itself).
                .background(WindowActionsBridge(coordinator: self.coordinator))
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
            MenuBarMenu(coordinator: self.coordinator)
        } label: {
            MenuBarLabel(coordinator: self.coordinator)
        }
    }
}

// MARK: - WindowActionsBridge

/// Invisible helper that reads the SwiftUI environment window actions and installs them as closures
/// on the coordinator. A plain `@Observable` class cannot read `@Environment(\.openWindow)`; this
/// bridge runs inside a `View` where the actions exist and forwards them once on appear.
private struct WindowActionsBridge: View {
    let coordinator: RecordingCoordinator

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
            }
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
        hasPostScreenGrantArg: Bool
    ) {
        self.permissionsService = permissionsService
        self.coordinator = coordinator
        _hasPostScreenGrantArg = State(initialValue: hasPostScreenGrantArg)
        _onboardingViewModel = State(initialValue: OnboardingViewModel(permissions: permissionsService))
        _mainViewModel = State(initialValue: MainViewModel(
            permissions: permissionsService,
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
