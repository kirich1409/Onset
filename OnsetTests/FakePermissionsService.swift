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
    private(set) var startScreenPollingCallCount = 0

    // MARK: - Grant-on-request hooks (Stage 4)

    /// When `true`, `requestCamera()` also sets `cameraStatus = .authorized` — models
    /// the AC-2 transition: system prompt granted → camera ✓ without restart.
    var grantCameraOnRequest = false

    /// When `true`, `requestMicrophone()` also sets `microphoneStatus = .authorized` —
    /// models the AC-2 transition for microphone.
    var grantMicrophoneOnRequest = false

    // MARK: - Cancellable polling hook (Stage 4)

    /// When `true`, `startScreenPolling()` returns a real `Task` that parks until
    /// cancelled (via `Task.yield()` loop) and sets `pollingTaskWasCancelled = true`.
    /// Default `false` keeps the original instantly-completed behaviour.
    var useCancellablePollingTask = false

    /// `true` after the cancellable polling task exits due to Task cancellation.
    private(set) var pollingTaskWasCancelled = false

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
        if self.grantCameraOnRequest {
            self.cameraStatus = .authorized
        }
    }

    func requestMicrophone() async {
        self.requestMicrophoneCallCount += 1
        if self.grantMicrophoneOnRequest {
            self.microphoneStatus = .authorized
        }
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
        self.startScreenPollingCallCount += 1
        guard self.useCancellablePollingTask else {
            // Default: return an immediately-completed task.
            return Task {}
        }
        // Cancellable path: park until the task is cancelled, then record cancellation.
        // The `@Sendable` closure captures `self` weakly; `pollingTaskWasCancelled` is
        // set back on `@MainActor` so the mutation is always isolated correctly.
        let markCancelled: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.pollingTaskWasCancelled = true }
        }
        return Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            markCancelled()
        }
    }

    func checkScreenStatusNow() {
        self.checkScreenStatusNowCallCount += 1
    }
}
