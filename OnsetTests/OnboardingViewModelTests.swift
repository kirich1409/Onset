@testable import Onset
import Testing

// MARK: - OnboardingViewModel tests

/// Tests cover the VM's observable behavior via `FakePermissionsService`.
///
/// The suite is `@MainActor` because both `OnboardingViewModel` and `FakePermissionsService`
/// are `@MainActor`-isolated, and every test drives them synchronously after construction.
///
/// Each `@Test` receives a fresh `FakePermissionsService` instance via `@Suite struct` isolation
/// — no shared mutable state, parallel-safe by default.
@Suite("OnboardingViewModel")
@MainActor
struct OnboardingViewModelTests {
    // MARK: - AC-2: Camera request transitions to authorized

    @Test("Camera «Разрешить» → fake grants → cameraStatus authorized, progress increments (AC-2)")
    func cameraRequest_grantsAccess_statusAuthorized() async {
        let fake = FakePermissionsService(camera: .notDetermined)
        fake.grantCameraOnRequest = true
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.cameraStatus == .notDetermined)
        #expect(sut.progress == 0)

        await sut.requestCamera()

        #expect(sut.cameraStatus == .authorized)
        #expect(sut.progress == 1)
        #expect(fake.requestCameraCallCount == 1)
        // isRequestingCamera must clear after the async request completes (AC-2, no restart)
        #expect(!sut.isRequestingCamera)
    }

    // MARK: - AC-2: Microphone request transitions to authorized

    @Test("Microphone «Разрешить» → fake grants → microphoneStatus authorized, progress increments (AC-2)")
    func microphoneRequest_grantsAccess_statusAuthorized() async {
        let fake = FakePermissionsService(microphone: .notDetermined)
        fake.grantMicrophoneOnRequest = true
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.microphoneStatus == .notDetermined)
        #expect(sut.progress == 0)

        await sut.requestMicrophone()

        #expect(sut.microphoneStatus == .authorized)
        #expect(sut.progress == 1)
        #expect(fake.requestMicrophoneCallCount == 1)
    }

    // MARK: - AC-7: Screen not granted + camera authorized → canContinueWithoutScreen available

    @Test("Screen notDetermined + camera authorized → canContinueWithoutScreen true (AC-7)")
    func screenNotDetermined_cameraAuthorized_canContinueWithoutScreen() {
        let fake = FakePermissionsService(screen: .notDetermined, camera: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.canContinueWithoutScreen)
        #expect(sut.canContinue) // camera is a valid video source
    }

    @Test("Screen notDetermined, camera notDetermined → canContinueWithoutScreen false (no video source)")
    func screenNotDetermined_cameraNotDetermined_cannotContinueWithoutScreen() {
        let fake = FakePermissionsService(screen: .notDetermined, camera: .notDetermined)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(!sut.canContinueWithoutScreen)
        #expect(!sut.canContinue) // no video source at all
    }

    // MARK: - AC-7: «Записать без звука» (mic not available)

    @Test("Camera authorized, microphone denied → canRecordWithoutAudio true (AC-7)")
    func cameraAuthorized_micDenied_canRecordWithoutAudio() {
        let fake = FakePermissionsService(screen: .denied, camera: .authorized, microphone: .denied)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.canRecordWithoutAudio)
        #expect(sut.canContinue)
    }

    @Test("Screen authorized, microphone denied → canRecordWithoutAudio true (AC-7)")
    func screenAuthorized_micDenied_canRecordWithoutAudio() {
        let fake = FakePermissionsService(screen: .authorized, microphone: .denied)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.canRecordWithoutAudio)
    }

    @Test("All three authorized → canRecordWithoutAudio false (full mode)")
    func allAuthorized_canRecordWithoutAudioFalse() {
        let fake = FakePermissionsService(screen: .authorized, camera: .authorized, microphone: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(!sut.canRecordWithoutAudio)
    }

    // MARK: - AC-4: Screen awaiting state (requestScreenRecording → isAwaitingScreen true)

    @Test("requestScreenRecording → isAwaitingScreen true, screenStatus still notDetermined (AC-4)")
    func requestScreenRecording_setsAwaitingState() {
        let fake = FakePermissionsService(screen: .notDetermined)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(!sut.isAwaitingScreen)

        sut.requestScreenRecording()

        #expect(sut.isAwaitingScreen)
        #expect(sut.screenStatus == .notDetermined) // domain status unchanged
        #expect(fake.requestScreenRecordingCallCount == 1)
    }

    @Test("openScreenRecordingSettings → requestScreenRecording + openSettings called, isAwaitingScreen true (AC-4)")
    func openScreenRecordingSettings_setsAwaitingState() {
        let fake = FakePermissionsService(screen: .notDetermined)
        let sut = OnboardingViewModel(permissions: fake)

        sut.openScreenRecordingSettings()

        #expect(sut.isAwaitingScreen)
        // requestScreenRecording is called first to register Onset in the TCC list,
        // then openScreenRecordingSettings opens System Settings (Fix 4).
        #expect(fake.requestScreenRecordingCallCount == 1)
        #expect(fake.openScreenRecordingSettingsCallCount == 1)
    }

    // MARK: - AC-4/AC-5: Screen status transitions to authorized → all-set condition

    @Test("Screen transitions to authorized → progress 1, effectivePermissions screenAvailable (AC-4/AC-5)")
    func screenGranted_livePickup_allSet() {
        let fake = FakePermissionsService(screen: .notDetermined)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.screenStatus == .notDetermined)
        #expect(sut.progress == 0)

        // Simulate polling discovering screen granted — VM is a live passthrough.
        fake.screenStatus = .authorized

        #expect(sut.screenStatus == .authorized)
        #expect(sut.progress == 1)
        #expect(sut.effectivePermissions.screenAvailable)
    }

    // MARK: - AC-5/AC-8: All three authorized → allGranted reflected, full mode

    // swiftformat:disable:next indent
    @Test("All three authorized → progress 3, progressHintText all-permissions, fullModeAvailable (AC-5, AC-8)")
    func allThreeAuthorized_allSet() {
        let fake = FakePermissionsService(screen: .authorized, camera: .authorized, microphone: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(fake.allGranted)
        #expect(sut.progress == 3)
        #expect(sut.progressHintText == "все разрешения активны")
        #expect(sut.canContinue)
        #expect(sut.effectivePermissions.fullModeAvailable)
        #expect(!sut.canContinueWithoutScreen)
        #expect(!sut.canRecordWithoutAudio)
    }

    // MARK: - Progress «N из 3» across combinations

    @Test(
        "progress == authorizedCount for all three statuses",
        arguments: [
            (PermissionStatus.notDetermined, PermissionStatus.notDetermined, PermissionStatus.notDetermined, 0),
            (.authorized, .notDetermined, .notDetermined, 1),
            (.notDetermined, .authorized, .notDetermined, 1),
            (.notDetermined, .notDetermined, .authorized, 1),
            (.authorized, .authorized, .notDetermined, 2),
            (.authorized, .notDetermined, .authorized, 2),
            (.notDetermined, .authorized, .authorized, 2),
            (.authorized, .authorized, .authorized, 3),
            (.denied, .denied, .denied, 0),
            (.denied, .authorized, .denied, 1),
            (.authorized, .denied, .authorized, 2),
        ]
    )
    func progress_equalsAuthorizedCount(
        screen: PermissionStatus,
        camera: PermissionStatus,
        microphone: PermissionStatus,
        expected: Int
    ) {
        let fake = FakePermissionsService(screen: screen, camera: camera, microphone: microphone)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.progress == expected)
    }

    // MARK: - Effective permissions consistency

    @Test("Mic remaining — progressHintText indicates mic remaining (AC-7 graceful path)")
    func micRemaining_progressHintText() {
        let fake = FakePermissionsService(screen: .authorized, camera: .authorized, microphone: .notDetermined)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.progressHintText == "остался микрофон")
        #expect(sut.effectivePermissions.microphoneAvailable == false)
        #expect(sut.effectivePermissions.canRecord) // can record without mic (screen available)
    }

    @Test("Screen denied (treated as notDetermined), camera/mic authorized → progressHintText waiting (AC-6 amended)")
    func screenDenied_progressHintText_waiting() {
        // Screen has no real denied state (CGPreflight is Bool-only); .denied is treated
        // the same as .notDetermined — the hint shows "waiting" rather than "blocked".
        let fake = FakePermissionsService(screen: .denied, camera: .authorized, microphone: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.progressHintText == "ждём запись экрана")
    }

    @Test("Screen notDetermined, camera/mic authorized → progressHintText waiting (AC-4)")
    func screenNotDetermined_cameraAndMicGranted_progressHintText_waiting() {
        let fake = FakePermissionsService(screen: .notDetermined, camera: .authorized, microphone: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(sut.progressHintText == "ждём запись экрана")
    }

    // MARK: - No video source — recording blocked

    @Test("No video source (screen denied, camera denied) → canContinue false (AC-7)")
    func noVideoSource_canContinueFalse() {
        let fake = FakePermissionsService(screen: .denied, camera: .denied, microphone: .authorized)
        let sut = OnboardingViewModel(permissions: fake)

        #expect(!sut.canContinue)
        #expect(!sut.effectivePermissions.canRecord)
    }

    // MARK: - Polling lifecycle

    @Test("startPolling returns a Task; cancelling it completes without leaking (AC-4 lifecycle)")
    func startPolling_cancel_noLeak() async {
        let fake = FakePermissionsService(screen: .notDetermined)
        fake.useCancellablePollingTask = true
        let sut = OnboardingViewModel(permissions: fake)

        let pollingTask = sut.startPolling()
        #expect(fake.startScreenPollingCallCount == 1)

        pollingTask.cancel()
        // Await completion — the cancellable fake task yields until cancelled.
        await pollingTask.value

        #expect(fake.pollingTaskWasCancelled)
    }

    // MARK: - refresh pass-through

    @Test("refresh() delegates to service refresh")
    func refresh_delegatesToService() {
        let fake = FakePermissionsService()
        let sut = OnboardingViewModel(permissions: fake)

        sut.refresh()

        #expect(fake.refreshCallCount == 1)
    }

    // MARK: - Settings deep-link wrappers (fix 5: VM owns the call-through, not the view)

    @Test("openCameraSettings() delegates to service (fix 5)")
    func openCameraSettings_delegatesToService() {
        let fake = FakePermissionsService()
        let sut = OnboardingViewModel(permissions: fake)

        sut.openCameraSettings()

        #expect(fake.openCameraSettingsCallCount == 1)
    }

    @Test("openMicrophoneSettings() delegates to service (fix 5)")
    func openMicrophoneSettings_delegatesToService() {
        let fake = FakePermissionsService()
        let sut = OnboardingViewModel(permissions: fake)

        sut.openMicrophoneSettings()

        #expect(fake.openMicrophoneSettingsCallCount == 1)
    }
}

// swiftlint:enable no_magic_numbers
