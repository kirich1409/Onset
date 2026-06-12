import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Section sub-views

extension MainView {
    // MARK: - Screen section

    var screenSection: some View {
        SectionCard(title: "ЭКРАН") {
            if self.model.isScreenDenied {
                ScreenDeniedRow(onReturnToOnboarding: self.onReturnToOnboarding)
            } else {
                ScreenEnabledContent(model: self.model)
            }
        }
    }

    // MARK: - Camera section

    /// Camera section — device picker plus optional live preview.
    ///
    /// The toggle from the original design has been removed (#224): the first row is
    /// the "Устройство" picker whose top item is "Выключена". Selecting any device
    /// enables the camera; selecting "Выключена" disables it. The preview appears only
    /// when a device is selected (`isCameraActive`). The denied TCC branch is preserved
    /// via `cameraPickerOrDenied` and is always visible (no outer enable-gate).
    var cameraSection: some View {
        SectionCard(title: "КАМЕРА") {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                self.cameraPickerOrDenied
                self.cameraPreview
            }
        }
    }

    /// Shows either the TCC-denied row or the device picker with an "Выключена" top item.
    ///
    /// Layout matches the reference design and neighbouring section rows (Дисплей, Микрофон):
    /// a "Устройство" label on the left and the menu picker on the right. The label is
    /// rendered as a plain `Text` inside an `HStack` so it respects the section's horizontal
    /// rhythm without requiring a `Form` context (consistent with `OutputFolderRow`).
    ///
    /// The "Камеры не найдены" case is embedded inside the picker branch: when `cameras`
    /// is empty the picker renders only the "Выключена" row, which is the correct UX
    /// (camera is effectively off and there is nothing to enable).
    @ViewBuilder
    private var cameraPickerOrDenied: some View {
        if self.model.isCameraDenied {
            CameraDeniedRow(onReturnToOnboarding: self.onReturnToOnboarding)
        } else {
            HStack {
                Text("Устройство")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("Устройство", selection: self.$model.cameraPickerSelection) {
                    Text("Выключена").tag(String?.none)
                    ForEach(self.model.cameras, id: \.uniqueID) { camera in
                        Text(self.model.cameraLabel(for: camera))
                            .tag(Optional(camera.uniqueID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Устройство камеры")
        }
    }

    @ViewBuilder
    private var cameraPreview: some View {
        // Show the preview only while an actual device is active; "Выключена" hides it.
        // `isCameraActive` is true iff cameraEnabled AND selectedCameraID is non-nil,
        // which is exactly the condition `cameraPickerSelection != nil` expresses via the VM.
        if self.model.isCameraActive {
            CameraPreviewRepresentable(sessionHandle: self.model.previewHandle)
                .id(self.model.previewGeneration)
                .aspectRatio(Metrics.previewAspectRatio, contentMode: .fit)
                // Cap on maxWidth (concrete in ScrollView) so the card is ≤140pt tall.
                // maxHeight is also set for documentation intent; maxWidth is the reliable
                // binding dimension since ScrollView propagates width, not height.
                .frame(
                    maxWidth: Metrics.previewMaxHeight * Metrics.previewAspectRatio,
                    maxHeight: Metrics.previewMaxHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.previewCornerRadius))
                // Center the narrower card within the section's full width.
                .frame(maxWidth: .infinity)
                .task(id: self.model.activeCamera?.uniqueID) {
                    await self.model.managePreview(for: self.model.activeCamera?.uniqueID)
                }
                .accessibilityLabel("Предварительный просмотр камеры")
        }
    }

    // MARK: - Microphone section

    var microphoneSection: some View {
        SectionCard(title: "МИКРОФОН") {
            if !self.model.isMicAvailable {
                MicrophoneUnavailableRow()
            } else if self.model.microphones.isEmpty {
                Text("Микрофоны не найдены")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Микрофон", selection: self.$model.selectedMicID) {
                    Text("Без микрофона").tag(String?.none)
                    ForEach(self.model.microphones, id: \.uniqueID) { mic in
                        Text(self.model.microphoneLabel(for: mic))
                            .tag(Optional(mic.uniqueID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Выберите микрофон")
            }
        }
    }

    // MARK: - Output section

    /// Output folder selection row — issue #225.
    var outputSection: some View {
        SectionCard(title: "ВЫВОД") {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                OutputFolderRow(folderURL: self.model.outputDirectoryURL) {
                    self.model.outputDirectoryURL = $0
                }
                Text("Каждая запись сохраняется в отдельную папку сессии.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - ScreenDeniedRow

private struct ScreenDeniedRow: View {
    let onReturnToOnboarding: () -> Void

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Доступ к экрану не выдан")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Разрешить") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Доступ к экрану не выдан. Нажмите «Разрешить» для перехода к настройкам разрешений."
        )
    }
}

// MARK: - ScreenEnabledContent

/// Shows the display picker when screen permission is granted.
///
/// The «Запись экрана» toggle was removed: screen is the mandatory video source in MVP
/// (decision B, issue #61). Camera-only recording is deferred post-MVP.
private struct ScreenEnabledContent: View {
    @Bindable var model: MainViewModel

    var body: some View {
        DisplayPickerContent(model: self.model)
    }
}

// MARK: - DisplayPickerContent

private struct DisplayPickerContent: View {
    @Bindable var model: MainViewModel

    var body: some View {
        if self.model.displays.isEmpty {
            Text("Дисплеи не найдены")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if self.model.displays.count == 1, let display = self.model.displays.first {
            SingleDisplayRow(label: self.model.displayLabel(for: display))
        } else {
            Picker("Дисплей", selection: self.$model.selectedDisplayID) {
                Text("Выберите дисплей").tag(CGDirectDisplayID?.none)
                ForEach(self.model.displays, id: \.displayID) { display in
                    Text(self.model.displayLabel(for: display))
                        .tag(Optional(display.displayID))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

// MARK: - SingleDisplayRow

/// Shows a single display's label with a checkmark — no picker needed (AC-1 auto-select).
private struct SingleDisplayRow: View {
    let label: String

    var body: some View {
        HStack {
            Image(systemName: "display")
                .frame(width: MainView.Metrics.iconColumnWidth)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(self.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Дисплей: \(self.label)")
    }
}

// MARK: - CameraDeniedRow

private struct CameraDeniedRow: View {
    let onReturnToOnboarding: () -> Void

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Доступ к камере не выдан")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Разрешить") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Доступ к камере не выдан.")
    }
}

// MARK: - MicrophoneUnavailableRow

private struct MicrophoneUnavailableRow: View {
    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "mic.slash")
                .foregroundStyle(.secondary)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text("Микрофон недоступен — запись без звука")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Микрофон недоступен. Запись будет вестись без звука.")
    }
}

// MARK: - OutputFolderRow

/// A single row in the output section showing the current base output directory and a «Выбрать…»
/// button that opens `NSOpenPanel`. Issue #225.
///
/// Displays the path abbreviated with a tilde so long `/Users/…` paths stay readable.
/// The `NSOpenPanel` sheet is presented as a child of the key window so it behaves as a
/// document-modal sheet on macOS and does not block other app windows.
private struct OutputFolderRow: View {
    /// The currently selected base output directory.
    let folderURL: URL
    /// Called with the URL the user picked in `NSOpenPanel`. Never called on cancellation.
    let onChoose: (URL) -> Void

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            // Info group: "Папка" label + folder icon + path text, collapsed into a single
            // AX element so VoiceOver reads the full sentence "Папка для записи: ~/Movies/Onset"
            // rather than three separate static-text fragments. `.accessibilityElement(children: .ignore)`
            // on the container hides the individual children and exposes label + value at container level.
            HStack(spacing: MainView.Metrics.accessorySpacing) {
                // A: visible "Папка" label on the left, matching the style of other section rows
                // (e.g. "Дисплей", "Устройство" in the reference design).
                Text("Папка")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: MainView.Metrics.outputFolderLabelWidth, alignment: .leading)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                // C: tooltip shows the full abbreviated path on hover.
                Text(self.abbreviatedPath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(self.abbreviatedPath)
            }
            // D: the container becomes the single AX element that VoiceOver reads as
            //    "Папка для записи: ~/Movies/Onset". Children are hidden from the AX tree.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Папка для записи")
            .accessibilityValue(self.abbreviatedPath)
            Spacer(minLength: 0)
            // "Выбрать…" is a separate interactive element — NOT inside the ignore container.
            Button("Выбрать…") {
                self.openPanel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Выбрать папку для сохранения")
        }
    }

    /// The folder path with `$HOME` collapsed to `~` for display.
    ///
    /// Replaces the home directory prefix with `~` — equivalent to `NSString.abbreviatingWithTildeInPath`
    /// but avoids bridging to the Objective-C reference type, which SwiftLint flags as `legacy_objc_type`.
    ///
    /// Bug fix (F): `hasPrefix(home)` incorrectly matched `/Users/foobar` when `home = /Users/foo`.
    /// Guard requires `home + "/"` as prefix (or exact equality for `$HOME` itself) to avoid false matches.
    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = self.folderURL.path
        if path == home {
            return "~"
        }
        let homeWithSlash = home + "/"
        if path.hasPrefix(homeWithSlash) {
            return "~/" + String(path.dropFirst(homeWithSlash.count))
        }
        return path
    }

    /// Opens a directory-picker `NSOpenPanel` as a child of the key window.
    ///
    /// `canCreateDirectories` is `true` so the user can create a new folder inline without
    /// leaving the dialog. `canChooseFiles` is `false` — only directories are valid targets.
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = self.folderURL
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку для сохранения записей"

        guard let window = NSApp.keyWindow else {
            // Fallback: run modally if there is no key window (should not happen in practice).
            if panel.runModal() == .OK, let url = panel.url {
                self.onChoose(url)
            }
            return
        }

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.onChoose(url)
            }
        }
    }
}
