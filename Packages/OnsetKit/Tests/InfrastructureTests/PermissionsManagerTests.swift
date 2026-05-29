import AVFoundation
import Domain
import Foundation
import Testing

@testable import Infrastructure

// MARK: - AVAuthorizationStatus → PermissionStatus mapping tests

/// Tests for the pure `AVAuthorizationStatus → PermissionStatus` mapping.
///
/// The live TCC calls (`AVCaptureDevice.requestAccess`, `CGPreflightScreenCaptureAccess`,
/// etc.) cannot be unit-tested without real system state and a signed app bundle — those
/// are L5 runtime-verification items. The mapping logic is extracted as a static function
/// and is fully testable without touching the OS.
@Suite("PermissionsManager AVAuthorizationStatus mapping")
struct PermissionsManagerMappingTests {

    @Test("notDetermined maps to .notDetermined")
    func notDetermined() {
        #expect(PermissionsManager.mapAVStatus(.notDetermined) == .notDetermined)
    }

    @Test("authorized maps to .authorized")
    func authorized() {
        #expect(PermissionsManager.mapAVStatus(.authorized) == .authorized)
    }

    @Test("denied maps to .denied")
    func denied() {
        #expect(PermissionsManager.mapAVStatus(.denied) == .denied)
    }

    @Test("restricted maps to .restricted")
    func restricted() {
        #expect(PermissionsManager.mapAVStatus(.restricted) == .restricted)
    }
}

// MARK: - Screen Recording notDetermined flag tests

/// Tests for the persisted "have we ever requested" flag that allows
/// `PermissionsManager` to distinguish `.notDetermined` from `.denied` for screen
/// recording (OS limitation: `CGPreflightScreenCaptureAccess()` returns a plain `Bool`).
///
/// These tests use an isolated in-memory `UserDefaults` suite so they do not touch
/// the application's real preferences store and are safe to run in parallel.
///
/// Post-request behavior (`.authorized` / `.denied`) depends on live OS state and
/// cannot be asserted in unit tests — that is L5 runtime-verification.
@Suite("PermissionsManager screen recording flag")
struct PermissionsManagerScreenRecordingFlagTests {

    /// Returns a fresh, isolated `UserDefaults` suite for each test.
    private func isolatedDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        // UserDefaults(suiteName:) always succeeds for a unique name; force-unwrap is safe.
        return UserDefaults(suiteName: suite)!
    }

    @Test("status(.screenRecording) is .notDetermined when flag is unset (fresh install)")
    func screenRecordingIsNotDeterminedWhenFlagUnset() {
        let defaults = isolatedDefaults()
        let manager = PermissionsManager(defaults: defaults)
        // No flag set → the OS has never been asked; must report .notDetermined regardless
        // of what CGPreflightScreenCaptureAccess() returns on this machine.
        #expect(manager.status(for: .screenRecording) == .notDetermined)
    }

    @Test("status(.screenRecording) is not .notDetermined after flag is set")
    func screenRecordingIsNotNotDeterminedWhenFlagSet() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "onset.permissions.screenRecording.requested")
        let manager = PermissionsManager(defaults: defaults)
        // Flag set → we have requested at least once. The actual result (.authorized or
        // .denied) depends on the live OS TCC state — just assert it is no longer .notDetermined.
        let status = manager.status(for: .screenRecording)
        #expect(status != .notDetermined)
    }
}

// MARK: - Domain seam substitutability

/// Proves that `PermissionsProviding` is substitutable with a test fake —
/// the Domain seam is not tied to any concrete type.
@Suite("PermissionsProviding seam substitutability")
struct PermissionsProvidingFakeTests {

    // MARK: - Fake implementation

    /// A fully in-process fake that does not touch TCC or the OS.
    final class FakePermissionsProvider: PermissionsProviding, @unchecked Sendable {
        private let fixedStatus: PermissionStatus

        init(fixedStatus: PermissionStatus) {
            self.fixedStatus = fixedStatus
        }

        func status(for kind: PermissionKind) -> PermissionStatus {
            fixedStatus
        }

        func request(_ kind: PermissionKind) async -> PermissionStatus {
            fixedStatus
        }
    }

    // MARK: - Tests

    @Test("Fake authorized provider returns .authorized for all kinds")
    func fakeReturnsAuthorized() async {
        let provider: any PermissionsProviding = FakePermissionsProvider(fixedStatus: .authorized)
        for kind in PermissionKind.allCases {
            #expect(provider.status(for: kind) == .authorized)
            let requested = await provider.request(kind)
            #expect(requested == .authorized)
        }
    }

    @Test("Fake denied provider returns .denied for all kinds")
    func fakeReturnsDenied() async {
        let provider: any PermissionsProviding = FakePermissionsProvider(fixedStatus: .denied)
        for kind in PermissionKind.allCases {
            #expect(provider.status(for: kind) == .denied)
        }
    }

    @Test("Fake notDetermined provider returns .notDetermined for all kinds")
    func fakeReturnsNotDetermined() async {
        let provider: any PermissionsProviding = FakePermissionsProvider(fixedStatus: .notDetermined)
        for kind in PermissionKind.allCases {
            #expect(provider.status(for: kind) == .notDetermined)
        }
    }

    @Test("PermissionsManager conforms to PermissionsProviding (type check)")
    func permissionsManagerConforms() {
        // Verifies the conformance compiles and the type is usable as the protocol.
        // The default-param init keeps the call site unchanged; injected defaults is
        // used in PermissionsManagerScreenRecordingFlagTests above.
        let manager: any PermissionsProviding = PermissionsManager()
        // Calling status() here would query the live OS; we only verify construction and type.
        _ = manager
    }
}
