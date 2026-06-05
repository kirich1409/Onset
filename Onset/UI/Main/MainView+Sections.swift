import CoreGraphics
import SwiftUI

// MARK: - Section sub-views

extension MainView {
    // MARK: - Screen section

    var screenSection: some View {
        SectionCard(title: "ЭКРАН") {
            if self.model.isScreenDenied {
                ScreenDeniedRow(onReturnToOnboarding: self.onReturnToOnboarding)
            } else {
                ScreenEnabledContent(model: self.model)
            }
        }
    }

    // MARK: - Camera section

    var cameraSection: some View {
        SectionCard(title: "КАМЕРА") {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                self.cameraPickerOrDenied
                self.cameraPreview
            }
        }
    }

    @ViewBuilder
    private var cameraPickerOrDenied: some View {
        if self.model.isCameraDenied {
            CameraDeniedRow(onReturnToOnboarding: self.onReturnToOnboarding)
        } else if self.model.cameras.isEmpty {
            Text("Камеры не найдены")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Picker("Камера", selection: self.$model.selectedCameraID) {
                Text("Без камеры").tag(String?.none)
                ForEach(self.model.cameras, id: \.uniqueID) { camera in
                    Text(self.model.cameraLabel(for: camera))
                        .tag(Optional(camera.uniqueID))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var cameraPreview: some View {
        CameraPreviewRepresentable(sessionHandle: self.model.previewHandle)
            .id(self.model.previewGeneration)
            .frame(height: Metrics.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.previewCornerRadius))
            .task(id: self.model.selectedCameraID) {
                await self.model.managePreview(for: self.model.selectedCameraID)
            }
            .accessibilityLabel(
                self.model.selectedCameraID == nil
                    ? "Предварительный просмотр: камера не выбрана"
                    : "Предварительный просмотр камеры"
            )
    }

    // MARK: - Microphone section

    var microphoneSection: some View {
        SectionCard(title: "МИКРОФОН") {
            if !self.model.isMicAvailable {
                MicrophoneUnavailableRow()
            } else if self.model.microphones.isEmpty {
                Text("Микрофоны не найдены")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Микрофон", selection: self.$model.selectedMicID) {
                    Text("Без микрофона").tag(String?.none)
                    ForEach(self.model.microphones, id: \.uniqueID) { mic in
                        Text(self.model.microphoneLabel(for: mic))
                            .tag(Optional(mic.uniqueID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Выберите микрофон")
            }
        }
    }
}

// MARK: - ScreenDeniedRow

private struct ScreenDeniedRow: View {
    let onReturnToOnboarding: () -> Void

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Доступ к экрану не выдан")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Разрешить") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Доступ к экрану не выдан. Нажмите «Разрешить» для перехода к настройкам разрешений."
        )
    }
}

// MARK: - ScreenEnabledContent

/// Shows the display picker when screen permission is granted.
///
/// The «Запись экрана» toggle was removed: screen is the mandatory video source in MVP
/// (decision B, issue #61). Camera-only recording is deferred post-MVP.
private struct ScreenEnabledContent: View {
    @Bindable var model: MainViewModel

    var body: some View {
        DisplayPickerContent(model: self.model)
    }
}

// MARK: - DisplayPickerContent

private struct DisplayPickerContent: View {
    @Bindable var model: MainViewModel

    var body: some View {
        if self.model.displays.isEmpty {
            Text("Дисплеи не найдены")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.model.displays.count == 1, let display = self.model.displays.first {
            SingleDisplayRow(label: self.model.displayLabel(for: display))
        } else {
            Picker("Дисплей", selection: self.$model.selectedDisplayID) {
                Text("Выберите дисплей").tag(CGDirectDisplayID?.none)
                ForEach(self.model.displays, id: \.displayID) { display in
                    Text(self.model.displayLabel(for: display))
                        .tag(Optional(display.displayID))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

// MARK: - SingleDisplayRow

/// Shows a single display's label with a checkmark — no picker needed (AC-1 auto-select).
private struct SingleDisplayRow: View {
    let label: String

    var body: some View {
        HStack {
            Image(systemName: "display")
                .frame(width: MainView.Metrics.iconColumnWidth)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(self.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Дисплей: \(self.label)")
    }
}

// MARK: - CameraDeniedRow

private struct CameraDeniedRow: View {
    let onReturnToOnboarding: () -> Void

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Доступ к камере не выдан")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Разрешить") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Доступ к камере не выдан.")
    }
}

// MARK: - MicrophoneUnavailableRow

private struct MicrophoneUnavailableRow: View {
    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "mic.slash")
                .foregroundStyle(.secondary)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Микрофон недоступен — запись без звука")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Микрофон недоступен. Запись будет вестись без звука.")
    }
}
