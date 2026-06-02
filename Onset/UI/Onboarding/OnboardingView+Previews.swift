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
#endif

#Preview("Cold start 0/3") {
    OnboardingView(
        viewModel: OnboardingViewModel(permissions: PreviewPermissionsService())
    ) {}
}

#Preview("Waiting 2/3 — screen not determined") {
    // Shows the 2/3 state (camera + mic granted, screen notDetermined).
    // The "Ожидание…" card chip activates at runtime when openScreenRecordingSettings()
    // is called; this preview shows the pre-awaiting notDetermined state for the same
    // permission count.
    OnboardingView(
        viewModel: OnboardingViewModel(
            permissions: PreviewPermissionsService(
                screen: .notDetermined,
                camera: .authorized,
                microphone: .authorized
            )
        )
    ) {}
}

#Preview("Screen denied 2/3") {
    OnboardingView(
        viewModel: OnboardingViewModel(
            permissions: PreviewPermissionsService(
                screen: .denied,
                camera: .authorized,
                microphone: .authorized
            )
        )
    ) {}
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
