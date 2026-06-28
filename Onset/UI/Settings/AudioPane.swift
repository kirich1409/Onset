import SwiftUI

// MARK: - AudioPane

/// The «Аудио» settings pane.
///
/// Read-only in v1: noise suppression and system audio are currently fixed off, each shown as a
/// static `LabeledContent` row (label + value, non-interactive) rather than a one-option `Picker`.
/// Rows announce to VoiceOver as static text, not buttons; the tab reads as informational.
@MainActor
struct AudioPane: View {
    var body: some View {
        Form {
            Section("Обработка") {
                LabeledContent("Шумоподавление", value: "Выкл")
                LabeledContent("Звук системы", value: "Выкл")
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
