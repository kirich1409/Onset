import SwiftUI

// MARK: - IndicationPane

/// The «Индикация» settings pane — the default-open tab.
///
/// Hosts the single real `.immediate` control in this category: the menu-bar elapsed-time timer
/// toggle. Bound to the shared `AppSettings` via `@Bindable`, so flipping it persists synchronously
/// (through the model's `didSet`) and re-renders the live `MenuBarLabel` at once. The timer policy
/// is `.immediate`, so the control is never gated during recording.
@MainActor
struct IndicationPane: View {
    /// The shared settings model. `@Bindable` so `$appSettings.showMenuBarTimer` is a write-through
    /// binding into the single in-memory source of truth (not a copied value).
    @Bindable var appSettings: AppSettings

    var body: some View {
        Form {
            Section("Строка меню") {
                Toggle("Показывать таймер записи", isOn: self.$appSettings.showMenuBarTimer)
            }

            Section("Dock") {
                // Read-only stub in v1: the Dock-icon indicator is not yet implemented, shown as a
                // static `LabeledContent` row (no chevron, non-interactive) like the other panes'
                // read-only rows.
                LabeledContent("Значок в Dock во время записи", value: "Выкл")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Индикация") {
        IndicationPane(appSettings: AppSettings(store: InMemorySettingsStore()))
            .formStyle(.grouped)
            .frame(width: SettingsLayout.width)
    }
#endif
