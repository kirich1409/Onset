import SwiftUI

// MARK: - SettingsTab

/// The selectable tabs of the Settings window, in display order.
///
/// `rawValue: String` is the stable key persisted via `@AppStorage` so the last-selected tab is
/// restored across launches. The enum is UI-only and therefore stays `@MainActor`-isolated (the
/// default under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`): its `RawRepresentable`/`Hashable`
/// conformances are used solely from main-actor view code (tab tags and the `@AppStorage` binding),
/// so — unlike `SettingApplyPolicy`/`ControlAvailability` — it needs no `nonisolated` witnesses.
enum SettingsTab: String {
    /// App-wide preferences (language, future general options).
    case general

    /// Menu-bar indication preferences (the elapsed-time timer). The default-open tab.
    case indication

    /// Recorded-video format display (codec/container/resolution/frame rate — read-only in v1).
    case video

    /// Camera preferences (mirror toggle + resolution display).
    case camera

    /// Audio preferences (noise suppression / system audio — read-only in v1).
    case audio

    /// The localized tab title shown in the toolbar tab item.
    var title: String {
        switch self {
        case .general: "Общие"
        case .indication: "Индикация"
        case .video: "Видео"
        case .camera: "Камера"
        case .audio: "Аудио"
        }
    }

    /// The SF Symbol name shown alongside the tab title.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .indication: "menubar.rectangle"
        case .video: "video"
        case .camera: "camera"
        case .audio: "waveform"
        }
    }
}

// MARK: - Layout constants

/// Fixed layout metrics for the Settings window panes.
///
/// A named constant avoids `no_magic_numbers` violations on the frame width and keeps every pane
/// (and its `#Preview`) the same width as the hosted `TabView`.
enum SettingsLayout {
    /// The fixed content width of the Settings window, matching macOS HIG preference panes.
    static let width: CGFloat = 480

    /// The fixed content height of the Settings window. Sized to comfortably fit the tallest pane
    /// (Камера: gated toggle + wrapping footer + resolution row) so single-control tabs (Индикация,
    /// Общие) do not collapse to a thin strip and switching tabs keeps a stable, non-jumping height.
    static let height: CGFloat = 360
}

// MARK: - SettingsView

/// Root view of the Settings (⌘,) window.
///
/// Receives its dependencies by explicit `init` (not `@Environment`): `appSettings` provides the
/// `@Bindable` source for the real toggles, and `coordinator` provides the observable
/// `isRecordingActive` flag used to gate the camera-mirror control during an active recording.
///
/// Built only from standard SwiftUI/AppKit components (`TabView`, `Form`, `Toggle`,
/// `LabeledContent`) per the project rule — no custom controls. The selected tab is persisted via
/// `@AppStorage` keyed on `SettingsTab.rawValue`, defaulting to `.indication`, so the window opens
/// on a content-bearing tab and remembers the last choice.
@MainActor
struct SettingsView: View {
    /// The shared, in-memory settings model. The single instance owned by `OnsetApp`.
    let appSettings: AppSettings

    /// The recording-lifecycle owner, read only for `isRecordingActive` (mirror gating).
    let coordinator: RecordingCoordinator

    /// Persisted raw value of the last-selected tab. Defaults to `SettingsTab.indication`.
    @AppStorage(SettingsKeys.selectedTab)
    private var selectedTabRaw: String = SettingsTab.indication.rawValue

    /// Two-way binding that maps the persisted raw string to a `SettingsTab`.
    ///
    /// Confining the `RawRepresentable` round-trip to this main-actor view code (rather than the
    /// `@AppStorage<SettingsTab>` generic overload) keeps the enum's conformance away from
    /// generic internals that would otherwise trip the `InferIsolatedConformances` enum trap.
    private var selection: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: self.selectedTabRaw) ?? .indication },
            set: { self.selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: self.selection) {
            GeneralPane()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)

            IndicationPane(appSettings: self.appSettings)
                .tabItem { Label(SettingsTab.indication.title, systemImage: SettingsTab.indication.symbol) }
                .tag(SettingsTab.indication)

            VideoPane()
                .tabItem { Label(SettingsTab.video.title, systemImage: SettingsTab.video.symbol) }
                .tag(SettingsTab.video)

            CameraPane(appSettings: self.appSettings, coordinator: self.coordinator)
                .tabItem { Label(SettingsTab.camera.title, systemImage: SettingsTab.camera.symbol) }
                .tag(SettingsTab.camera)

            AudioPane()
                .tabItem { Label(SettingsTab.audio.title, systemImage: SettingsTab.audio.symbol) }
                .tag(SettingsTab.audio)
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
    }
}

// MARK: - Preview

#if DEBUG
    #Preview("Settings") {
        SettingsView(
            appSettings: AppSettings(store: InMemorySettingsStore()),
            coordinator: RecordingCoordinator()
        )
    }
#endif
