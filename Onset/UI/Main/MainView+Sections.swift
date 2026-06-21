// swiftlint:disable file_length
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

    /// Shows either the TCC-denied row, a "Камеры не найдены" placeholder, or the device picker.
    ///
    /// Layout matches the reference design: a "Устройство" label on the left and the menu
    /// picker on the right. The label is rendered as a plain `Text` inside an `HStack` so it
    /// respects the section's horizontal rhythm without requiring a `Form` context (consistent
    /// with `OutputFolderRow`).
    ///
    /// Branch priority (top-to-bottom wins):
    /// 1. TCC denied → `CameraDeniedRow`.
    /// 2. Cameras available → device picker. When a disconnected notice is also present
    ///    (`disconnectedCameraName != nil`), `CameraUnavailableRow(hasAlternatives: true)` is
    ///    appended below the picker so the user can immediately select a replacement device.
    /// 3. No cameras AND disconnected notice → `CameraUnavailableRow(hasAlternatives: false)`
    ///    (no picker because there is nothing to pick from).
    /// 4. No cameras AND no disconnected notice → non-interactive "Камеры не найдены" text,
    ///    parallel to the microphone section's empty state.
    @ViewBuilder
    private var cameraPickerOrDenied: some View {
        if self.model.isCameraDenied {
            CameraDeniedRow(onReturnToOnboarding: self.onReturnToOnboarding)
        } else if !self.model.cameras.isEmpty {
            // Picker is always shown when alternatives exist — even in the disconnected state
            // so the user can immediately choose a replacement device.
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
                .accessibilityLabel("Устройство камеры")
            }
            if let name = self.model.disconnectedCameraName {
                // Supplementary notice below the picker: explains why the previously
                // selected camera is no longer in the list. hasAlternatives = true because
                // the picker above contains at least one device to switch to.
                CameraUnavailableRow(cameraName: name, hasAlternatives: true)
            }
        } else if let name = self.model.disconnectedCameraName {
            // No alternatives — only the unavailability notice, without a picker.
            CameraUnavailableRow(cameraName: name, hasAlternatives: false)
        } else {
            Text("Камеры не найдены")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Камеры не найдены")
        }
    }

    @ViewBuilder
    private var cameraPreview: some View {
        // Show the preview area only when a device is selected; "Выключена" (nil picker) hides it.
        // `isCameraActive` reflects whether the picker has a concrete device selected, surfaced
        // via the VM's `isCameraActive` predicate.
        if self.model.isCameraActive {
            // Hoist once per body pass — used at three sites below.
            let pending = self.model.cameraPlaceholderPending
            ZStack {
                // Live preview — always mounted when active so the NSView layer is warm.
                // `.id(previewGeneration)` forces recreation when the camera device changes;
                // until the handle arrives the layer paints black (covered by the overlay below).
                CameraPreviewRepresentable(sessionHandle: self.model.previewHandle)
                    .id(self.model.previewGeneration)
                    .accessibilityLabel("Предварительный просмотр камеры")
                    // Hide the black NSView layer from VoiceOver while the placeholder is shown
                    // so the user only hears the status label, not both.
                    .accessibilityHidden(pending)

                // Placeholder — shown while `previewHandle == nil` (source not yet started or failed).
                // Fades in/out via the ZStack-level `.animation` driven by `cameraPlaceholderPending`.
                // Branches internally: spinner while connecting, error icon when `previewFailed`.
                // Label is iPhone-specific when `isContinuityCamera` via `cameraPlaceholderLabel`.
                if pending {
                    self.cameraConnectingOverlay
                }
            }
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
            // Crossfade between placeholder and live states. Scoped to `cameraPlaceholderPending`
            // so it does NOT animate the `.id()`-driven NSView recreation.
            .animation(
                .easeInOut(duration: Metrics.connectingCrossfadeDuration),
                value: pending
            )
            // `.task` sits on the ZStack container, not on the representable, so generation
            // bumps (`.id` on the inner view) do not cancel and re-fire `managePreview`.
            .task(id: self.model.activeCamera?.uniqueID) {
                await self.model.managePreview(for: self.model.activeCamera?.uniqueID)
            }
        }
    }

    /// Visible and accessibility label for the camera placeholder — iPhone-specific when applicable.
    ///
    /// Thin wrapper over `CameraPreviewLabel.text` so the visible label and the VoiceOver
    /// announcement (`previewAnnouncement`) read the SAME source (#256). `nil` only for `.live`,
    /// where the placeholder is not shown; the connecting copy is the safe fallback.
    private var cameraPlaceholderLabel: String {
        let isPhone = self.model.activeCamera?.isContinuityCamera == true
        return CameraPreviewLabel.text(for: self.model.previewState, isContinuity: isPhone)
            ?? (isPhone ? "Подключение iPhone…" : "Подключение камеры…")
    }

    /// Placeholder shown while the preview session is starting or has failed.
    ///
    /// Occupies the same box as the live preview (sized by the parent ZStack) so no layout
    /// jump occurs. Background matches the card surface (`controlBackgroundColor`).
    /// Branches on `previewFailed`: spinner + label while connecting, error icon + label on failure.
    private var cameraConnectingOverlay: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            VStack(spacing: Metrics.connectingSpinnerSpacing) {
                if self.model.previewFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.medium)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
                Text(self.cameraPlaceholderLabel)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        // `.accessibilityLabel` gives the on-demand current-state read; the frequent-updates
        // trait was removed (#256) — it re-spoke the label for a focused user on top of the
        // explicit VoiceOver announcement (double speech).
        .accessibilityLabel(self.cameraPlaceholderLabel)
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
                HStack {
                    Text("Устройство")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Picker("Устройство", selection: self.$model.selectedMicID) {
                        Text("Без микрофона").tag(String?.none)
                        ForEach(self.model.microphones, id: \.uniqueID) { mic in
                            Text(self.model.microphoneLabel(for: mic))
                                .tag(Optional(mic.uniqueID))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Устройство микрофона")
                }
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
            HStack {
                Text("Дисплей")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("Дисплей", selection: self.$model.selectedDisplayID) {
                    Text("Выберите дисплей").tag(CGDirectDisplayID?.none)
                    ForEach(self.model.displays, id: \.displayID) { display in
                        Text(self.model.displayLabel(for: display))
                            .tag(Optional(display.displayID))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Дисплей экрана")
            }
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

// MARK: - CameraUnavailableRow

/// Shown when `disconnectedCameraName != nil`: the previously selected camera has disappeared
/// (e.g. unplugged or lid closed) while the camera was enabled. Distinguishes an involuntary
/// disconnection from an explicit "Выключена" selection so the user is not confused.
///
/// When other cameras are available (`hasAlternatives == true`), the row appends a hint to
/// select another device so the user immediately knows recovery is possible without dismissing
/// the panel and inspecting the picker.
private struct CameraUnavailableRow: View {
    /// Display name of the missing camera device — shown in UI only, never logged.
    let cameraName: String
    /// When `true`, the hint "выберите другую камеру" is appended to the row label.
    let hasAlternatives: Bool

    var body: some View {
        HStack(spacing: MainView.Metrics.accessorySpacing) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: MainView.Metrics.iconColumnWidth)
                .accessibilityHidden(true)
            Text(self.rowText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.rowText)
    }

    private var rowText: String {
        if self.hasAlternatives {
            "Камера «\(self.cameraName)» недоступна — выберите другую камеру"
        } else {
            "Камера «\(self.cameraName)» недоступна"
        }
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

// swiftlint:enable file_length
