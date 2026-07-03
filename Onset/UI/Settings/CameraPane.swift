import SwiftUI

// MARK: - CameraPane

/// The «Камера» settings pane.
///
/// Hosts the camera-mirror toggle — a `.nextRecordingStart` control: outside a recording, a mirror
/// change takes effect from the next recording's start. During an active recording the control is
/// locked — not because of any preview divergence (the main window, the sole camera-preview
/// carrier, is dismissed at recording start, so no live preview is on screen), but because the
/// one-shot pipeline cannot reconfigure mid-record: an editable toggle would silently have NO
/// effect on the in-progress file, which is worse than a clearly-disabled control. Camera
/// resolution is a read-only `LabeledContent` row in v1: the value reads «Максимальное» because the
/// camera auto-selects the maximum 16:9 format (up to 1080p) — explicit resolution/fps selection is
/// future work (#276).
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
    /// change takes effect. Rendered as the always-visible `Section` footer, which VoiceOver already
    /// announces with the control — so it is the single explanatory channel (no `accessibilityHint`
    /// duplicate, which would make VoiceOver read the same text twice).
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
            } footer: {
                Text(self.mirrorCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Камера") {
                LabeledContent("Разрешение", value: "Максимальное")
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
