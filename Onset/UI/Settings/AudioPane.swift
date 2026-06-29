import SwiftUI

// MARK: - AudioPane

/// The «Аудио» settings pane.
///
/// Read-only in v1: system audio is currently fixed off, shown as a static `LabeledContent` row
/// (label + value, non-interactive) rather than a one-option `Picker`. The row announces to
/// VoiceOver as static text, not a button; the tab reads as informational.
@MainActor
struct AudioPane: View {
    var body: some View {
        Form {
            Section("Источники") {
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
