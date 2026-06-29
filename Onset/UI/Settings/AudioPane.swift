import SwiftUI

// MARK: - AudioPane

/// The «Аудио» settings pane.
///
/// Read-only in v1: shows the system-audio status row (currently fixed off) as a static
/// `LabeledContent` row (label + value, non-interactive) rather than a one-option `Picker` — system
/// audio is a future capability surfaced read-only. The row announces to VoiceOver as static text,
/// not a button. A `Section` footer notes that the microphone is chosen in the main recording
/// window, so this tab does not contradict what the app records by default.
@MainActor
struct AudioPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Звук системы", value: "Выкл")
            } footer: {
                Text("Микрофон выбирается в главном окне.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Аудио") {
        AudioPane()
            .formStyle(.grouped)
            .frame(width: SettingsLayout.width)
    }
#endif
