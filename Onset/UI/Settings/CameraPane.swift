import SwiftUI

// MARK: - CameraPane

/// The «Камера» settings pane.
///
/// Hosts the camera-mirror toggle — a `.nextRecordingStart` control: the live preview reflects a
/// change instantly, but a recording honors the value captured at its next start. During an active
/// recording the control is locked. Camera resolution is a read-only `LabeledContent` row in v1.
@MainActor
struct CameraPane: View {
    /// The shared settings model. `@Bindable` so `$appSettings.cameraMirror` writes through to the
    /// single in-memory source of truth (and persists via the model's `didSet`).
    @Bindable var appSettings: AppSettings

    /// The recording-lifecycle owner, read only for the observable `isRecordingActive` flag.
    let coordinator: RecordingCoordinator

    /// Availability of the mirror control, derived purely from its apply-policy and whether a
    /// recording is currently active. `.disabled` while recording, `.enabled` otherwise.
    private var mirrorAvailability: ControlAvailability {
        ControlAvailability.classify(
            policy: .nextRecordingStart,
            isRecordingActive: self.coordinator.isRecordingActive
        )
    }

    /// The caption shown beneath the mirror toggle, explaining either why it is locked or when the
    /// change takes effect. Also mirrored into the control's `accessibilityHint`.
    private var mirrorCaption: String {
        switch self.mirrorAvailability {
        case .disabled: "Недоступно во время записи"
        case .enabled: "Превью обновляется сразу, в запись — со следующего старта"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Зеркальное отображение", isOn: self.$appSettings.cameraMirror)
                    .disabled(self.mirrorAvailability == .disabled)
                    .accessibilityHint(self.mirrorCaption)
            } footer: {
                Text(self.mirrorCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Камера") {
                LabeledContent("Разрешение", value: "1080p")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Камера") {
        CameraPane(
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: RecordingCoordinator()
        )
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
    }
#endif
