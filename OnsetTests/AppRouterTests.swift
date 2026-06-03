@testable import Onset
import Testing

// MARK: - AppRouter.route tests

@Suite("AppRouter.route")
struct AppRouterRouteTests {
    // MARK: - AC-9: No relaunch arg, all granted → main

    @Test("All granted, no arg → .main (AC-8, AC-9)")
    func allGranted_noArg_main() {
        let route = AppRouter.route(
            allGranted: true,
            hasPostScreenGrantArg: false,
            screenPreflightGranted: true
        )
        #expect(route == .main)
    }

    @Test("All granted, no arg, preflight false → .main")
    func allGranted_noArg_preflightFalse_main() {
        let route = AppRouter.route(
            allGranted: true,
            hasPostScreenGrantArg: false,
            screenPreflightGranted: false
        )
        #expect(route == .main)
    }

    // MARK: - Onboarding path (no arg, not all granted)

    @Test("Not all granted, no arg → .onboarding")
    func notAllGranted_noArg_onboarding() {
        let route = AppRouter.route(
            allGranted: false,
            hasPostScreenGrantArg: false,
            screenPreflightGranted: false
        )
        #expect(route == .onboarding)
    }

    @Test("Screen denied, no arg → .onboarding (revoke returns to onboarding)")
    func screenDenied_noArg_onboarding() {
        let route = AppRouter.route(
            allGranted: false,
            hasPostScreenGrantArg: false,
            screenPreflightGranted: false
        )
        #expect(route == .onboarding)
    }

    // MARK: - AC-5: Post-screen-grant arg, preflight true → allSet

    @Test("hasArg, preflight true → .allSet (AC-5)")
    func hasArg_preflightTrue_allSet() {
        let route = AppRouter.route(
            allGranted: true,
            hasPostScreenGrantArg: true,
            screenPreflightGranted: true
        )
        #expect(route == .allSet)
    }

    @Test("hasArg, preflight true, not allGranted → .onboarding (camera/mic still pending)")
    func hasArg_preflightTrue_notAllGranted_onboarding() {
        // .allSet requires allGranted == true. If screen is granted but camera/mic are still
        // pending, routing falls back to .onboarding so the user can complete those steps.
        let route = AppRouter.route(
            allGranted: false,
            hasPostScreenGrantArg: true,
            screenPreflightGranted: true
        )
        #expect(route == .onboarding)
        #expect(route != .allSet)
    }

    // MARK: - AC-5 anti-loop: hasArg, preflight false → status-based routing (no .allSet)

    @Test("hasArg, preflight false → .onboarding not .allSet (anti-loop, AC-5)")
    func hasArg_preflightFalse_notAllGranted_onboarding() {
        let route = AppRouter.route(
            allGranted: false,
            hasPostScreenGrantArg: true,
            screenPreflightGranted: false
        )
        #expect(route == .onboarding)
        #expect(route != .allSet)
    }

    @Test("hasArg, preflight false, allGranted → .main not .allSet (anti-loop)")
    func hasArg_preflightFalse_allGranted_main() {
        // If somehow all granted but preflight false → fall through to status routing.
        // This is the anti-loop branch: no repeated allSet if screen isn't confirmed.
        let route = AppRouter.route(
            allGranted: true,
            hasPostScreenGrantArg: true,
            screenPreflightGranted: false
        )
        #expect(route == .main)
        #expect(route != .allSet)
    }
}

// MARK: - AppRouter.shouldTriggerRelaunch tests

@Suite("AppRouter.shouldTriggerRelaunch")
struct AppRouterRelaunchTests {
    @Test("notDetermined → authorized: front edge → should relaunch")
    func notDetermined_toAuthorized_shouldRelaunch() {
        #expect(AppRouter.shouldTriggerRelaunch(
            previous: .notDetermined,
            current: .authorized
        ))
    }

    @Test("authorized → authorized: no edge → no relaunch (already granted, no transition)")
    func authorized_toAuthorized_noRelaunch() {
        #expect(!AppRouter.shouldTriggerRelaunch(
            previous: .authorized,
            current: .authorized
        ))
    }

    @Test("notDetermined → notDetermined: no edge → no relaunch")
    func notDetermined_toNotDetermined_noRelaunch() {
        #expect(!AppRouter.shouldTriggerRelaunch(
            previous: .notDetermined,
            current: .notDetermined
        ))
    }

    @Test("denied → authorized: front edge → should relaunch (revoke then re-grant)")
    func denied_toAuthorized_shouldRelaunch() {
        #expect(AppRouter.shouldTriggerRelaunch(
            previous: .denied,
            current: .authorized
        ))
    }

    @Test("authorized → notDetermined: no edge → no relaunch (revoke detected, not grant)")
    func authorized_toNotDetermined_noRelaunch() {
        #expect(!AppRouter.shouldTriggerRelaunch(
            previous: .authorized,
            current: .notDetermined
        ))
    }
}
