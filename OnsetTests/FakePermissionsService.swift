import Foundation
@testable import Onset

// MARK: - Fake

/// A fully in-memory fake implementation of `PermissionsProviding` for use in unit tests.
///
/// All state is per-instance so Swift Testing's parallel-by-default execution is safe:
/// each `@Test` in a `@Suite struct` receives a fresh instance.
///
/// Stage 4 (OnboardingViewModel tests) can reuse this fake directly.
@MainActor
final class FakePermissionsService: PermissionsProviding {
    // MARK: - Configurable statuses

    var screenStatus: PermissionStatus
    var cameraStatus: PermissionStatus
    var microphoneStatus: PermissionStatus

    // MARK: - Call tracking (for assertion purposes in Stage 4 VM tests)

    private(set) var refreshCallCount = 0
    private(set) var requestCameraCallCount = 0
    private(set) var requestMicrophoneCallCount = 0
    private(set) var requestScreenRecordingCallCount = 0
    private(set) var openScreenRecordingSettingsCallCount = 0
    private(set) var openCameraSettingsCallCount = 0
    private(set) var openMicrophoneSettingsCallCount = 0
    private(set) var checkScreenStatusNowCallCount = 0

    // MARK: - Init

    init(
        screen: PermissionStatus = .notDetermined,
        camera: PermissionStatus = .notDetermined,
        microphone: PermissionStatus = .notDetermined
    ) {
        self.screenStatus = screen
        self.cameraStatus = camera
        self.microphoneStatus = microphone
    }

    // MARK: - PermissionsProviding

    var effectivePermissions: EffectivePermissions {
        EffectivePermissions.compute(
            screen: self.screenStatus,
            camera: self.cameraStatus,
            microphone: self.microphoneStatus
        )
    }

    var progress: Int {
        self.effectivePermissions.authorizedCount
    }

    var allGranted: Bool {
        self.screenStatus == .authorized &&
            self.cameraStatus == .authorized &&
            self.microphoneStatus == .authorized
    }

    func refresh() {
        self.refreshCallCount += 1
    }

    func requestCamera() async {
        self.requestCameraCallCount += 1
    }

    func requestMicrophone() async {
        self.requestMicrophoneCallCount += 1
    }

    func requestScreenRecording() {
        self.requestScreenRecordingCallCount += 1
    }

    func openScreenRecordingSettings() {
        self.openScreenRecordingSettingsCallCount += 1
    }

    func openCameraSettings() {
        self.openCameraSettingsCallCount += 1
    }

    func openMicrophoneSettings() {
        self.openMicrophoneSettingsCallCount += 1
    }

    func startScreenPolling() -> Task<Void, Never> {
        // Return an immediately-completed task — polling is not exercised in unit tests.
        Task {}
    }

    func checkScreenStatusNow() {
        self.checkScreenStatusNowCallCount += 1
    }
}
