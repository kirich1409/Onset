import SwiftUI

// MARK: - GeneralPane

/// The «Общие» settings pane.
///
/// Read-only in v1: language is fixed to Russian and shown as a static `LabeledContent` row, not a
/// one-option `Picker` (which would read as a broken control). Interactive options appear here only
/// when a real choice exists. The row announces to VoiceOver as static text, not a button.
@MainActor
struct GeneralPane: View {
    var body: some View {
        Form {
            Section("Язык") {
                LabeledContent("Язык интерфейса", value: "Русский")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Общие") {
        GeneralPane()
            .formStyle(.grouped)
            .frame(width: SettingsLayout.width)
    }
#endif
