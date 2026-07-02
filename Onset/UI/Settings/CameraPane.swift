import SwiftUI

// MARK: - CameraPane

/// The «Камера» settings pane.
///
/// Hosts the camera-mirror toggle and the camera-stabilization toggle (#297) — both
/// `.nextRecordingStart` controls: outside a recording, a change takes effect from the next
/// recording's start. During an active recording the controls are locked — not because of any
/// preview divergence (the main window, the sole camera-preview carrier, is dismissed at
/// recording start, so no live preview is on screen), but because the one-shot pipeline cannot
/// reconfigure mid-record: an editable toggle would silently have NO effect on the in-progress
/// file, which is worse than a clearly-disabled control. Each toggle lives in its OWN `Section`
/// with its own footer caption — the footer is the single explanatory channel (VoiceOver reads
/// it with the control), and one footer per two controls would blur which caption explains what.
/// The stabilization footer explicitly states the effect applies to the RECORDING only: the live
/// preview runs outside the stabilization stage, and without that line a user would toggle it
/// on, see shake in the preview, and conclude the feature is broken. Camera resolution is a
/// read-only `LabeledContent` row in v1: the value reads «Максимальное» because the camera
/// auto-selects the maximum 16:9 format — explicit resolution/fps selection is future work (#276).
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

    /// Availability of the stabilization toggle (#297) — same `.nextRecordingStart` policy as the
    /// mirror: the session-fixed crop geometry and buffer pools cannot change mid-record.
    private var stabilizationAvailability: ControlAvailability {
        ControlAvailability.classify(
            policy: .nextRecordingStart,
            isRecordingActive: self.coordinator.isRecordingActive
        )
    }

    /// The stabilization footer caption (#297 AC-5, texts fixed by the spec's Decisions Made).
    /// The enabled text MUST state the effect is recording-only (the preview is not stabilized)
    /// and that the image is slightly cropped; the disabled text uses the mirror control's
    /// formula so the pane speaks one language.
    private var stabilizationCaption: String {
        switch self.stabilizationAvailability {
        case .disabled: "Недоступно во время записи"
        case .enabled: "Подавляет дрожание от вибраций (например, при наборе текста). "
            + "Действует только на запись — превью не стабилизируется. "
            + "Изображение записи немного обрезается по краям. Применяется со следующей записи"
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

            Section {
                Toggle("Стабилизация камеры", isOn: self.$appSettings.cameraStabilization)
                    .disabled(self.stabilizationAvailability == .disabled)
            } footer: {
                Text(self.stabilizationCaption)
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
