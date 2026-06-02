import SwiftUI

// MARK: - Camera and microphone card sub-views

/// Device card (camera + microphone) view builders and their derived model properties.
///
/// Extracted into a separate extension to keep `OnboardingView` body length within limits.
extension OnboardingView {
    // MARK: - Icon colors

    enum DeviceCardColors {
        static let cameraIconRed: CGFloat = 0.15
        static let cameraIconGreen: CGFloat = 0.65
        static let micIconRed: CGFloat = 0.95
        static let micIconGreen: CGFloat = 0.55
        static let micIconBlue: CGFloat = 0.15
    }

    // MARK: - Camera card

    var cameraCard: some View {
        PermissionCardView(
            iconSymbol: "camera.fill",
            iconColor: Color(
                red: DeviceCardColors.cameraIconRed,
                green: DeviceCardColors.cameraIconGreen,
                blue: DeviceCardColors.cameraIconGreen
            ),
            title: "Камера",
            subtitle: self.cameraCardSubtitle,
            status: self.cameraCardStatus,
            actionButton: self.cameraCardButton,
            instructions: nil,
            showInstructions: .constant(false)
        )
    }

    var cameraCardStatus: PermissionCardStatus {
        if viewModel.isRequestingCamera { return .awaiting }
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
            "Камера готова."

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
                action: { viewModel.permissionsService.openCameraSettings() },
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
            iconColor: Color(
                red: DeviceCardColors.micIconRed,
                green: DeviceCardColors.micIconGreen,
                blue: DeviceCardColors.micIconBlue
            ),
            title: "Микрофон",
            subtitle: self.microphoneCardSubtitle,
            status: self.microphoneCardStatus,
            actionButton: self.microphoneCardButton,
            instructions: nil,
            showInstructions: .constant(false)
        )
    }

    var microphoneCardStatus: PermissionCardStatus {
        if viewModel.isRequestingMicrophone { return .awaiting }
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
            "Микрофон готов."

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
                action: { viewModel.permissionsService.openMicrophoneSettings() },
                style: .secondary
            )

        case .authorized:
            nil
        }
    }
}
