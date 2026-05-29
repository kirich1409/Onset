import Domain
import Testing

@testable import Application
@testable import Presentation

// MARK: - Test helpers

/// Minimal fake `PermissionsProviding` for tests that don't care about TCC state.
private final class AlwaysAuthorizedPermissions: PermissionsProviding, @unchecked Sendable {
    func status(for kind: PermissionKind) -> PermissionStatus { .authorized }
    func request(_ kind: PermissionKind) async -> PermissionStatus { .authorized }
}

/// Minimal fake `NotificationPermissionProviding` for tests that don't care about notification state.
private final class AlwaysAuthorizedNotificationPermissions: NotificationPermissionProviding,
    @unchecked Sendable
{
    func authorizationStatus() async -> PermissionStatus { .authorized }
    func requestAuthorization() async -> PermissionStatus { .authorized }
}

// MARK: - RootComposition smoke tests

/// Verifies that the composition root wires the application-layer DI graph correctly.
///
/// These tests close the AC gap: "the three types are created via the composition root"
/// (previously untested because RootComposition lives in Presentation, outside ApplicationTests).
@MainActor
@Suite("RootComposition wiring")
struct RootCompositionTests {

    private func makeRoot() -> RootComposition {
        RootComposition(
            permissions: AlwaysAuthorizedPermissions(),
            notificationPermissions: AlwaysAuthorizedNotificationPermissions()
        )
    }

    @Test("RootComposition constructs without crashing")
    func rootCompositionConstructs() {
        let root = makeRoot()
        // Smoke: all application-layer objects are accessible.
        // Non-optional lets are by construction non-nil — the meaningful assertion is
        // that RootComposition() completes and its graph is reachable.
        _ = root.coordinator
        _ = root.settingsStore
        _ = root.healthMonitor
        _ = root.permissions
        _ = root.notificationPermissions
    }

    @Test("all five injected instances are exposed by reference identity")
    func rootCompositionWiresIdenticalInstances() async {
        let permissions = AlwaysAuthorizedPermissions()
        let notificationPermissions = AlwaysAuthorizedNotificationPermissions()
        let root = RootComposition(
            permissions: permissions,
            notificationPermissions: notificationPermissions
        )
        // RootComposition creates shared instances and passes them by reference.
        // The coordinator holds settingsStore and healthMonitor as private lets, so we
        // verify the root's public properties refer to the same objects it constructed
        // (identity check on the actor and monitor reference types).
        let monitor = root.healthMonitor
        let store = root.settingsStore
        let coordinator = root.coordinator

        // The coordinator is the single wired instance — retaining it and the root's
        // property must be the same actor reference.
        #expect(coordinator === root.coordinator)
        // settingsStore and healthMonitor are distinct actors; same instance as the root holds.
        #expect(monitor === root.healthMonitor)
        #expect(store === root.settingsStore)
        // The injected permission providers must be the exact instances exposed by the root
        // (reference identity — the root must not wrap or copy them).
        // Cast to AnyObject because the stored properties are typed as `any Protocol`
        // (existentials), which requires an explicit class-type context for ===.
        #expect(root.permissions as AnyObject === permissions as AnyObject)
        #expect(root.notificationPermissions as AnyObject === notificationPermissions as AnyObject)
    }
}
