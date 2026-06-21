import AppKit
import Foundation
import os
import UniformTypeIdentifiers

// MARK: - Logger

nonisolated private let saveCoordinatorLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DiagnosticsSaveCoordinator"
)

// MARK: - DiagnosticsExportError

/// Errors surfaced from `DiagnosticsSaveCoordinator.export()`.
enum DiagnosticsExportError: Error, Equatable {
    /// The user cancelled the NSSavePanel.
    case cancelled
    /// The formatted text could not be written to the chosen URL.
    case writeFailed
}

// MARK: - DiagnosticsSaveCoordinator

/// Orchestrates a full diagnostic export: collect → format → NSSavePanel → write → reveal.
///
/// `@MainActor` because `NSSavePanel` must run on the main thread. The coordinator is
/// owned by `OnsetApp` and passed into `MenuBarMenu` as a closure seam so the menu itself
/// stays a pure reader of `RecordingCoordinator`.
///
/// The look-back window (`lookBackInterval`) defaults to 30 minutes — enough context for
/// recent crashes / hangs without generating multi-MB files from long sessions.
@Observable
@MainActor
final class DiagnosticsSaveCoordinator {
    // MARK: - Configuration

    /// How far back to collect log entries (default: 30 minutes).
    static let defaultLookBackInterval: TimeInterval = 1800 // 30 min × 60 s

    // MARK: - State (observable)

    /// `true` while an export is in progress; gates the menu-button enabled state.
    private(set) var isExporting = false

    // MARK: - Dependencies

    @ObservationIgnored
    private let logProvider: any LogEntryProviding
    @ObservationIgnored
    private let lookBackInterval: TimeInterval

    // MARK: - Init

    init(
        logProvider: any LogEntryProviding = OSLogEntryProvider(),
        lookBackInterval: TimeInterval = DiagnosticsSaveCoordinator.defaultLookBackInterval
    ) {
        self.logProvider = logProvider
        self.lookBackInterval = lookBackInterval
    }

    // MARK: - Public API

    /// Runs the full export flow: collect → format → NSSavePanel → write → (optional) reveal.
    ///
    /// Errors are logged and swallowed — the caller (menu-bar button) does not need to handle them;
    /// a user cancellation via the save panel is treated as a non-error and silently ignored.
    func export() {
        guard !self.isExporting else {
            saveCoordinatorLogger.debug("Export already in progress — ignoring duplicate request")
            return
        }
        Task { await self.performExport() }
    }

    /// Collects log entries and formats them into a report string.
    ///
    /// Exposed for testing: isolates the collect + format steps from `NSSavePanel` I/O.
    ///
    /// - Parameter now: The reference timestamp used as the upper bound and embedded in the
    ///   report header. Defaults to the current date.
    /// - Returns: The formatted report content.
    /// - Throws: Propagates `LogEntryProviding` errors if the log store cannot be read.
    func makeReport(now: Date = Date()) async throws -> String {
        let since = now.addingTimeInterval(-self.lookBackInterval)
        let entries = try await self.logProvider.entries(since: since)
        return LogExportFormatter.format(entries: entries, generatedAt: now)
    }

    // MARK: - Private implementation

    private func performExport() async {
        self.isExporting = true
        defer { self.isExporting = false }

        do {
            let now = Date()
            let content = try await self.makeReport(now: now)
            let filename = LogExportFormatter.filename(for: now)

            guard let url = await self.runSavePanel(defaultFilename: filename) else {
                saveCoordinatorLogger.info("User cancelled the diagnostics save panel")
                return
            }

            try self.writeContent(content, to: url)
            saveCoordinatorLogger.info("Diagnostics exported to \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            saveCoordinatorLogger.error("Diagnostics export failed: \(error)")
        }
    }

    /// Presents `NSSavePanel` and returns the chosen URL, or `nil` if the user cancelled.
    private func runSavePanel(defaultFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Экспортировать диагностику"
        panel.prompt = "Сохранить"
        panel.message = "Выберите место для сохранения диагностического файла Onset."

        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow ?? NSPanel())
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Writes `content` to `url` atomically.
    private func writeContent(_ content: String, to url: URL) throws {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveCoordinatorLogger.error("Failed to write diagnostics to \(url.path): \(error)")
            throw DiagnosticsExportError.writeFailed
        }
    }
}
