import SwiftUI

// MARK: - Camera and microphone card sub-views

/// Device card (camera + microphone) view builders and their derived model properties.
///
/// Extracted into a separate extension to keep `OnboardingView` body length within limits.
extension OnboardingView {
    // MARK: - Camera card

    var cameraCard: some View {
        PermissionCardView(
            iconSymbol: "camera.fill",
            iconColor: PermissionIconColor.camera,
            title: "Камера",
            subtitle: self.cameraCardSubtitle,
            status: self.cameraCardStatus,
            actionButton: self.cameraCardButton,
            instructions: nil,
            instructionsHeader: nil,
            showInstructions: .constant(false)
        )
    }

    var cameraCardStatus: PermissionCardStatus {
        if viewModel.isRequestingCamera {
            return .awaiting
        }
        switch viewModel.cameraStatus {
        case .notDetermined:
            return .required

        case .authorized:
            return .authorized

        case .denied, .restricted:
            return .denied
        }
    }

    var cameraCardSubtitle: String {
        switch viewModel.cameraStatus {
        case .notDetermined:
            "Чтобы записывать вас в кадре."

        case .authorized:
            // Show the real device name when available (matching mockup "Logitech MX Brio").
            viewModel.defaultCameraName.map { "\($0)." } ?? "Камера готова."

        case .denied, .restricted:
            "Доступ запрещён. Откройте настройки."
        }
    }

    var cameraCardButton: PermissionCardActionButton? {
        switch viewModel.cameraStatus {
        case .notDetermined:
            .init(
                label: "Разрешить",
                action: { Task { await viewModel.requestCamera() } },
                style: .primary
            )

        case .denied, .restricted:
            .init(
                label: "Открыть настройки",
                action: { viewModel.openCameraSettings() },
                style: .secondary
            )

        case .authorized:
            nil
        }
    }

    // MARK: - Microphone card

    var microphoneCard: some View {
        PermissionCardView(
            iconSymbol: "mic.fill",
            iconColor: PermissionIconColor.microphone,
            title: "Микрофон",
            subtitle: self.microphoneCardSubtitle,
            status: self.microphoneCardStatus,
            actionButton: self.microphoneCardButton,
            instructions: nil,
            instructionsHeader: nil,
            showInstructions: .constant(false)
        )
    }

    var microphoneCardStatus: PermissionCardStatus {
        if viewModel.isRequestingMicrophone {
            return .awaiting
        }
        switch viewModel.microphoneStatus {
        case .notDetermined:
            return .required

        case .authorized:
            return .authorized

        case .denied, .restricted:
            return .denied
        }
    }

    var microphoneCardSubtitle: String {
        switch viewModel.microphoneStatus {
        case .notDetermined:
            "Без него запись будет без вашего голоса."

        case .authorized:
            // Show the real device name when available (matching mockup "MacBook Pro — микрофон").
            viewModel.defaultMicrophoneName.map { "\($0)." } ?? "Микрофон готов."

        case .denied, .restricted:
            "Доступ запрещён. Откройте настройки."
        }
    }

    var microphoneCardButton: PermissionCardActionButton? {
        switch viewModel.microphoneStatus {
        case .notDetermined:
            .init(
                label: "Разрешить",
                action: { Task { await viewModel.requestMicrophone() } },
                style: .primary
            )

        case .denied, .restricted:
            .init(
                label: "Открыть настройки",
                action: { viewModel.openMicrophoneSettings() },
                style: .secondary
            )

        case .authorized:
            nil
        }
    }
}
