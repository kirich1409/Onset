import SwiftUI

// MARK: - Preview support

#if DEBUG
    /// In-memory fake for use in previews — defined in the app target (not the test target)
    /// so `#Preview` blocks compile without `@testable`.
    @MainActor
    final class PreviewPermissionsService: PermissionsProviding {
        var screenStatus: PermissionStatus
        var cameraStatus: PermissionStatus
        var microphoneStatus: PermissionStatus

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

        var defaultCameraName: String? {
            "Preview Camera"
        }

        var defaultMicrophoneName: String? {
            "Preview Microphone"
        }

        var primaryDisplayDescription: String? {
            "1920×1080"
        }

        func refresh() {}
        func requestCamera() async {}
        func requestMicrophone() async {}
        func requestScreenRecording() {}
        func openScreenRecordingSettings() {}
        func openCameraSettings() {}
        func openMicrophoneSettings() {}
        func startScreenPolling() -> Task<Void, Never> {
            Task {}
        }

        func checkScreenStatusNow() {}

        init(
            screen: PermissionStatus = .notDetermined,
            camera: PermissionStatus = .notDetermined,
            microphone: PermissionStatus = .notDetermined
        ) {
            self.screenStatus = screen
            self.cameraStatus = camera
            self.microphoneStatus = microphone
        }
    }

    #Preview("Cold start 0/3") {
        OnboardingView(
            viewModel: OnboardingViewModel(permissions: PreviewPermissionsService())
        ) {}
    }

    #Preview("Waiting 2/3 — screen awaiting") {
        // Shows the 2/3 state with "Ожидание…" chip active (isAwaitingScreen = true).
        let viewModel = OnboardingViewModel(
            permissions: PreviewPermissionsService(
                screen: .notDetermined,
                camera: .authorized,
                microphone: .authorized
            )
        )
        // Simulate the awaiting state that activates after tapping "Открыть настройки".
        viewModel.requestScreenRecording()
        return OnboardingView(viewModel: viewModel) {}
    }

    #Preview("Mic remaining 2/3") {
        OnboardingView(
            viewModel: OnboardingViewModel(
                permissions: PreviewPermissionsService(
                    screen: .authorized,
                    camera: .authorized,
                    microphone: .notDetermined
                )
            )
        ) {}
    }

    #Preview("Screen denied, camera+mic granted — Продолжить без экрана") {
        // Screen denied + camera+mic authorized → single "Продолжить без экрана" primary.
        let viewModel = OnboardingViewModel(
            permissions: PreviewPermissionsService(
                screen: .denied,
                camera: .authorized,
                microphone: .authorized
            )
        )
        // Simulate awaiting so the "Проверить снова" footer is shown (matches the design ref PNG).
        viewModel.requestScreenRecording()
        return OnboardingView(viewModel: viewModel) {}
    }

    #Preview("Camera only, no mic — Продолжить без экрана (overlap cell)") {
        // S=0, C=1, M=0: cameraOnly and noAudio both true → resolves to camera-only label.
        OnboardingView(
            viewModel: OnboardingViewModel(
                permissions: PreviewPermissionsService(
                    screen: .notDetermined,
                    camera: .authorized,
                    microphone: .denied
                )
            )
        ) {}
    }
#endif
