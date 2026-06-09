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
/// - «Версия X.Y.Z (N)» — non-interactive build attribution label for beta feedback (#166).
/// - «Выход»
///
/// **Recording / Degraded:**
/// - «Остановить» — calls `coordinator.stop()` (the AC-9 menu-bar stop path).
/// - «Открыть окно записи» — focuses the recording window.
///
/// Pure reader of `coordinator` — no own state.
@MainActor
struct MenuBarMenu: View {
    let coordinator: RecordingCoordinator

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

        Button("Открыть окно записи") {
            self.openWindow(id: WindowID.recording)
            AppActivation.bringToFront()
        }
    }
}
