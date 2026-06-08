import SwiftUI

// MARK: - Preview support

#if DEBUG
    /// In-memory fake for use in `MainView` previews — defined in the app target so `#Preview` compiles
    /// without `@testable`. Does not perform any hardware I/O.
    @MainActor
    final class PreviewPermissionsServiceForMain: PermissionsProviding {
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
            self.screenStatus == .authorized
                && self.cameraStatus == .authorized
                && self.microphoneStatus == .authorized
        }

        var defaultCameraName: String? {
            nil
        }

        var defaultMicrophoneName: String? {
            nil
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

    @MainActor
    private func makePreviewModel(
        screen: PermissionStatus = .authorized,
        camera: PermissionStatus = .authorized,
        microphone: PermissionStatus = .authorized,
        displays: [Display] = [],
        cameras: [CameraDevice] = [],
        microphones: [MicrophoneDevice] = []
    )
    -> MainViewModel {
        let perms = PreviewPermissionsServiceForMain(
            screen: screen,
            camera: camera,
            microphone: microphone
        )
        let coordinator = RecordingCoordinator()
        return MainViewModel(
            permissions: perms,
            coordinator: coordinator,
            discoverDisplays: { _ in displays },
            discoverCameras: { _ in cameras },
            discoverMicrophones: { _ in microphones }
        )
    }

    #Preview("No permissions — empty state") {
        let model = makePreviewModel(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        return MainView(model: model) {}
    }

    #Preview("Screen only — 1 display auto-selected") {
        let display = Display(displayID: 1, pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60)
        let model = makePreviewModel(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .notDetermined,
            displays: [display]
        )
        return MainView(model: model) {}
    }

    #Preview("Full — screen + camera + mic") {
        let display = Display(displayID: 1, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60)
        let camera = CameraDevice(uniqueID: "camera-1", formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
        let mic = MicrophoneDevice(uniqueID: "mic-1")
        let model = makePreviewModel(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized,
            displays: [display],
            cameras: [camera],
            microphones: [mic]
        )
        return MainView(model: model) {}
    }

    #Preview("Mic available but unselected — record disabled AC-2b") {
        let display = Display(displayID: 1, pixelWidth: 1920, pixelHeight: 1080, refreshHz: 0)
        let mic = MicrophoneDevice(uniqueID: "mic-1")
        let model = makePreviewModel(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .authorized,
            displays: [display],
            microphones: [mic]
        )
        // selectedMicID stays nil (no auto-select) — shows disabled reason
        return MainView(model: model) {}
    }

    #Preview("No mic — record without audio AC-2c") {
        let display = Display(displayID: 1, pixelWidth: 1920, pixelHeight: 1080, refreshHz: 0)
        let model = makePreviewModel(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .denied,
            displays: [display]
        )
        return MainView(model: model) {}
    }

    #Preview("Camera toggle off — picker and preview hidden") {
        let display = Display(displayID: 1, pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60)
        let camera = CameraDevice(uniqueID: "camera-1", formats: [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30, maxFps: 60),
        ])
        let mic = MicrophoneDevice(uniqueID: "mic-1")
        let model = makePreviewModel(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized,
            displays: [display],
            cameras: [camera],
            microphones: [mic]
        )
        model.cameraEnabled = false
        return MainView(model: model) {}
    }
#endif
