import SwiftUI

// MARK: - ScreenPane

/// The «Экран» settings pane.
///
/// Read-only in v1: the recorded-screen format is currently fixed, so each parameter is shown as a
/// static `LabeledContent` row (label + value, no chevron, non-interactive) rather than a
/// one-option `Picker`. Frame rate reads «авто/исходный» — the camera delivers a variable/lower
/// rate, so a single number would imply a false guarantee. Rows announce to VoiceOver as static
/// text, not buttons; the tab reads as informational, not broken.
@MainActor
struct ScreenPane: View {
    var body: some View {
        Form {
            Section("Формат записи экрана") {
                LabeledContent("Кодек", value: "HEVC")
                LabeledContent("Контейнер", value: "MP4")
                LabeledContent("Разрешение", value: "Исходное")
                LabeledContent("Частота кадров", value: "авто/исходный")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Экран") {
        ScreenPane()
            .formStyle(.grouped)
            .frame(width: SettingsLayout.width)
    }
#endif
