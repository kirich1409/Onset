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
private enum WindowID {
    static let main = "onboarding"
    static let recording = "recording"
}

// MARK: - AppActivationDelegate

/// Satisfies the `NSApplicationDelegateAdaptor` requirement for the app struct.
///
/// Focus on launch is handled by `WindowActionsBridge.onAppear` instead of here.
/// `applicationDidFinishLaunching` fires before SwiftUI materialises the `Window` scene,
/// so calling `NSApp.activate()` at that point wins no focus — the window does not yet
/// exist and the system leaves Finder frontmost. The activation call therefore lives in
/// `WindowActionsBridge.onAppear`, deferred by one runloop turn via `Task { @MainActor in }`,
/// guaranteeing the window is on screen before activation is requested.
@MainActor
final class AppActivationDelegate: NSObject, NSApplicationDelegate {}

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

    // MARK: - App delegate (activation policy under LSUIElement)

    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appDelegate

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
        // Force the launch window to present under LSUIElement: an accessory-at-launch app does NOT
        // auto-open its `Window` scene, which would regress onboarding (Epic 2). `.presented` opens
        // it at launch; `WindowActionsBridge.onAppear` activates the app once the window exists.
        .defaultLaunchBehavior(.presented)

        // The recording window (#37). Phase 0 renders a minimal placeholder; the real RecordingView
        // lands in Phase 2. Suppressed under XCTest for the same reason as the main window.
        Window("Onset — запись", id: WindowID.recording) {
            if isRunningUnderXCTest {
                EmptyView()
            } else {
                RecordingWindowPlaceholder(coordinator: self.coordinator)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
        // Do NOT auto-open at launch — only the main window presents on launch; the recording window
        // opens on Record (AC-3). Without this the second Window scene would also pop at startup.
        .defaultLaunchBehavior(.suppressed)

        // Menu bar item (#38 foundation). Phase 0 ships a minimal but functional menu so the app is
        // usable as a menu-bar app; the full Idle / Recording / Degraded states land in #38.
        // Suppressed under XCTest so test hosts do not accumulate competing status items.
        MenuBarExtra(isInserted: .constant(!isRunningUnderXCTest)) {
            MenuBarContent(coordinator: self.coordinator)
        } label: {
            // Minimal reactive label: ● while recording, ○ at rest.
            Image(systemName: self.coordinator.phase == .recording ? "record.circle.fill" : "circle")
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
                // Activate the app once the window has materialised. `applicationDidFinishLaunching`
                // fires before SwiftUI creates the Window scene, so activation there is a no-op for
                // LSUIElement apps. A one-runloop-turn Task hop guarantees the window is on screen
                // before NSApp.activate() is called. Skipped under XCTest (AppActivation guard).
                Task { @MainActor in
                    AppActivation.bringToFront()
                    appLogger.info("Main window appeared — activated app for launch focus")
                }
            }
    }
}

// MARK: - RecordingWindowPlaceholder

/// **Phase-2 placeholder.** A minimal stand-in for the real `RecordingView` (#37), wired only to
/// read the coordinator's live `phase` / `elapsed` so the scene + window choreography can be
/// verified in Phase 0. Replace entirely when landing #37.
private struct RecordingWindowPlaceholder: View {
    private enum Metrics {
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 24
    }

    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            Text(self.coordinator.phase == .recording ? "● ИДЁТ ЗАПИСЬ" : "Запись не идёт")
                .font(.headline)
            Text(ElapsedFormatter.string(from: self.coordinator.elapsed))
                .font(.system(.largeTitle, design: .monospaced))
            Text("Заглушка окна записи — реализация в #37")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ElapsedFormatter

/// Formats whole seconds as `mm:ss`.
///
/// Avoids `String(format:)`, whose variadic initializer trips `SWIFT_STRICT_MEMORY_SAFETY` (the
/// project enables strict memory safety). Pads each component to two digits manually.
private enum ElapsedFormatter {
    private static let secondsPerMinute = 60
    private static let twoDigitThreshold = 10

    static func string(from seconds: Int) -> String {
        let minutes = seconds / self.secondsPerMinute
        let remainder = seconds % self.secondsPerMinute
        return "\(self.padded(minutes)):\(self.padded(remainder))"
    }

    private static func padded(_ value: Int) -> String {
        value < self.twoDigitThreshold ? "0\(value)" : "\(value)"
    }
}

// MARK: - MenuBarContent

/// **Minimal menu (#38 foundation).** A functional menu so the app is usable as a menu-bar app:
/// open the main window, and quit. The full Idle / Recording / Degraded menus land in #38.
private struct MenuBarContent: View {
    let coordinator: RecordingCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Открыть Onset") {
            self.openWindow(id: WindowID.main)
            AppActivation.bringToFront()
        }
        Divider()
        Button("Выход") {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - AppActivation

/// Brings the (menu-bar accessory) app to the front.
///
/// Used in two places:
/// - **Launch**: called from `WindowActionsBridge.onAppear` (deferred via `Task { @MainActor in }`)
///   after the main window has materialised — ensures Onset takes focus on first launch.
/// - **Reopen**: called synchronously from menu-bar button handlers after `openWindow(id:)` — ensures
///   Onset is frontmost when the user reopens the window from the status menu.
///
/// `NSApp.activate()` is the macOS 14+ non-deprecated form; `activate(ignoringOtherApps:)` is
/// deprecated and rejected by `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`.
/// Skipped under XCTest: test hosts must not steal focus during the L5 capture suite.
private enum AppActivation {
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
