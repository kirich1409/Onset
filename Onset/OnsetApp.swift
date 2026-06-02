import AppKit
import os
import SwiftUI

// MARK: - Logger

nonisolated private let appLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "OnsetApp"
)

// MARK: - OnsetApp

@main
struct OnsetApp: App {
    // MARK: - Window defaults

    private enum WindowDefaults {
        static let width: CGFloat = 460
        static let height: CGFloat = 560
    }

    // MARK: - Composition root

    /// The single `PermissionsService` instance shared across all scenes.
    ///
    /// Created at app-init time so statuses are snapshotted immediately and routing
    /// decisions on the first render are based on real data.
    @State private var permissionsService = PermissionsService(
        screenPermission: ScreenRecordingPermission(),
        capturePermission: CaptureDevicePermission(),
        relauncher: AppRelauncher()
    )

    var body: some Scene {
        Window("Onset", id: "onboarding") {
            RootView(permissionsService: self.permissionsService)
        }
        // Fixed-size window that wraps the content — prevents user resizing.
        .windowResizability(.contentSize)
        .defaultSize(width: WindowDefaults.width, height: WindowDefaults.height)
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

    // MARK: - View-owned VM for onboarding

    @State private var onboardingViewModel: OnboardingViewModel

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init(permissionsService: PermissionsService) {
        self.permissionsService = permissionsService

        let hasArg = CommandLine.arguments.contains(AppRelauncher.postScreenGrantArg)
        if hasArg {
            // Clear the anti-loop flag so a subsequent revoke-detect doesn't re-relaunch.
            AppRelauncher.clearPendingRelaunch()
            appLogger.info("Started with --post-screen-grant; cleared pendingScreenGrantRelaunch flag")
        }

        _hasPostScreenGrantArg = State(initialValue: hasArg)
        _onboardingViewModel = State(initialValue: OnboardingViewModel(permissions: permissionsService))
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
                    self.hasPostScreenGrantArg = false
                    appLogger.info("AllSet acknowledged — cleared post-screen-grant arg")
                }

            case .main:
                MainView(effectivePermissions: self.permissionsService.effectivePermissions) {
                    // Clear the bypass so AppRouter re-evaluates to .onboarding.
                    // This is the escape hatch from the "no permissions" blocked state
                    // that appears when the user tapped «Позже» at 0/3 (AC-7 graceful path).
                    self.bypassToMain = false
                    appLogger.info("Returned from main to onboarding — cleared bypassToMain")
                }
            }
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
