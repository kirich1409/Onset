import AppKit
import os
import SwiftUI

// MARK: - Logger

nonisolated private let menuBarMenuLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "MenuBarMenu"
)

// MARK: - MenuBarMenu

/// Context menu content for the status-item menu bar (#38).
///
/// Two menu configurations driven by `RecordingCoordinator.phase`:
///
/// **Idle / Main / Finished:**
/// - «Открыть Onset» — opens and focuses the main window.
/// - «Начать запись» — dispatches `coordinator.menuBarRecordIntent` when the main window is
///   mounted (intent installed by `MainView.onAppear`), or opens the main window as fallback.
/// - «Показывать таймер записи» — checkmark toggle mirroring the Индикация settings tab (same
///   `showMenuBarTimer`).
/// - «Экспортировать диагностику» — collects recent OS log entries and presents NSSavePanel.
/// - «Версия X.Y.Z (N)» — non-interactive build attribution label for beta feedback (#166).
/// - «Выход»
///
/// **Recording / Degraded:**
/// - «Остановить» — calls `coordinator.stop()` (the AC-9 menu-bar stop path).
/// - «Открыть окно записи» — focuses the recording window.
/// - «Показывать таймер записи» — checkmark toggle mirroring the Индикация settings tab (same
///   `showMenuBarTimer`).
///
/// Reads `coordinator`/`diagnosticsCoordinator` for menu state; binds `appSettings.showMenuBarTimer`
/// (read-write via the timer toggle). Holds no own `@State`.
@MainActor
struct MenuBarMenu: View {
    let coordinator: RecordingCoordinator
    let diagnosticsCoordinator: DiagnosticsSaveCoordinator

    /// The shared settings model. `@Bindable` so the menu's timer toggle writes through to the same
    /// `showMenuBarTimer` as the Индикация settings tab (single in-memory source of truth).
    @Bindable var appSettings: AppSettings

    @Environment(\.openWindow)
    private var openWindow

    var body: some View {
        if self.coordinator.phase == .recording {
            self.recordingMenu
        } else {
            self.idleMenu
        }
    }

    // MARK: - Idle menu

    @ViewBuilder
    private var idleMenu: some View {
        Button("Открыть Onset") {
            self.openWindow(id: WindowID.main)
            AppActivation.bringToFront()
        }

        Button("Начать запись") {
            if let intent = self.coordinator.menuBarRecordIntent {
                // Main window is mounted: run AC-2 guards via MainViewModel.record().
                intent()
            } else {
                // Main window not visible: open it so the user can configure sources.
                self.openWindow(id: WindowID.main)
                AppActivation.bringToFront()
            }
        }

        // Mirrors the Индикация settings tab's «Показывать таймер записи» — same `showMenuBarTimer`.
        // Renders as a stock checkmark menu item; reachable here so the preference can be flipped
        // without opening Settings.
        Toggle("Показывать таймер записи", isOn: self.$appSettings.showMenuBarTimer)

        Divider()

        // ⌘, only fires with a focused window, so a menu-bar-centric app needs an explicit entry
        // to reach the Settings scene when no other window is open. `SettingsLink` opens it.
        SettingsLink {
            Text("Настройки…")
        }
        // Render «⌘,» next to the item and make the shortcut work while the menu is open —
        // the standard app-menu ⌘, only fires when Onset is frontmost (menu-bar-first usage).
        .keyboardShortcut(",", modifiers: .command)

        Button("Экспортировать диагностику") {
            self.diagnosticsCoordinator.export()
        }
        .disabled(self.diagnosticsCoordinator.isExporting)

        Divider()

        // Version label for beta feedback attribution (#166). Non-interactive.
        Text("Версия \(AppVersionFormatter.bundleVersionDisplay)")
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        Button("Выход") {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Recording menu

    @ViewBuilder
    private var recordingMenu: some View {
        Button("Остановить") {
            menuBarMenuLogger.info("Stop triggered from menu bar")
            // stop() is async — wrap in unstructured Task (fire-and-forget is safe; the
            // coordinator's isStopping guard handles concurrent calls).
            Task { await self.coordinator.stop() }
        }
        // ⌘⌥⌃R — mirrors the global Carbon hotkey in OnsetApp.swift (AC-9, #242).
        // Carbon and SwiftUI .keyboardShortcut are separate event paths; no double-trigger guard needed.
        .keyboardShortcut(KeyEquivalent("r"), modifiers: [.command, .option, .control])

        Button("Открыть окно записи") {
            self.openWindow(id: WindowID.recording)
            AppActivation.bringToFront()
        }

        // Mirrors the Индикация settings tab's «Показывать таймер записи» — same `showMenuBarTimer`.
        // The counter shows during recording, but it's a persistent indication preference, so keep
        // it reachable in the recording menu too.
        Toggle("Показывать таймер записи", isOn: self.$appSettings.showMenuBarTimer)
    }
}
