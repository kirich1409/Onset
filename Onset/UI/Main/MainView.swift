import AppKit
import AVFoundation
import os
import SwiftUI

// MARK: - Logger

nonisolated private let mainViewLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "MainView"
)

// MARK: - MainView

/// The main recording configuration screen (#36).
///
/// Shows three source sections (screen, camera, microphone), the Record button,
/// and a footer with a brief summary. Delegates all logic to `MainViewModel`.
///
/// View states:
/// - No permissions (AC-2d): empty state with return-to-onboarding button
/// - Normal: section cards + Record button
///
/// Section sub-views live in `MainView+Sections.swift`.
/// Preview doubles and `#Preview` blocks live in `MainView+Previews.swift`.
@MainActor
struct MainView: View {
    // MARK: - Metrics

    enum Metrics {
        static let outerPaddingH: CGFloat = 20
        static let outerPaddingV: CGFloat = 16
        static let sectionSpacing: CGFloat = 12
        /// Aspect ratio for the camera preview card (16:9 landscape).
        static let previewAspectRatio: CGFloat = 16.0 / 9.0 // swiftlint:disable:this no_magic_numbers
        /// Maximum height for the camera preview card: still compact inside the fixed 460×660 window (#74/#316),
        /// but tall enough that the 16:9 preview nearly fills the 392pt card inner width, minimizing the
        /// pillarbox margins on either side (#267). At 180pt the preview is 320pt wide → ~36pt margin per side.
        static let previewMaxHeight: CGFloat = 180
        static let recordButtonHeight: CGFloat = 44
        static let rowSpacing: CGFloat = 8
        static let iconColumnWidth: CGFloat = 16
        static let emptyIconSize: CGFloat = 40
        static let noPermissionsTextPaddingH: CGFloat = 32
        static let noPermissionsSpacing: CGFloat = 16
        static let recordButtonDotSize: CGFloat = 10
        static let recordButtonWithoutAudioOpacity: CGFloat = 0.75
        static let recordButtonHSpacing: CGFloat = 6
        static let previewCornerRadius: CGFloat = 8
        static let accessorySpacing: CGFloat = 8
        static let footerBottomPad: CGFloat = 8
        /// Crossfade duration for the connecting-overlay ↔ live-preview transition.
        static let connectingCrossfadeDuration = 0.25
        /// Vertical spacing between the spinner and the label inside the connecting overlay.
        static let connectingSpinnerSpacing: CGFloat = 8
        /// Width of the "Папка" label in the output-folder row — wide enough to align
        /// with the icon column while leaving room for the path text.
        static let outputFolderLabelWidth: CGFloat = 48
    }

    // MARK: - Dependencies

    @Bindable
    var model: MainViewModel

    /// Called when the user wants to return to onboarding.
    let onReturnToOnboarding: () -> Void

    // MARK: - State

    /// Drives the post-stop alert. The only post-stop alert is the write-error alert (the file was
    /// not saved). Using `alert(item:)` with an enum keeps a single presentation slot and a single
    /// alert-resolution entry point (`resolvedAlert`).
    @State
    private var pendingAlert: PostStopAlert?

    // MARK: - Body

    var body: some View {
        Group {
            if self.model.showNoPermissionsState {
                self.noPermissionsView
            } else {
                self.mainContent
            }
        }
        // Fixed size matching the window scene's .windowResizability(.contentSize).
        // ScrollView inside mainContent allows scrolling if content overflows at any
        // Dynamic Type size, while the window itself remains non-resizable.
        .frame(width: WindowDefaults.width, height: WindowDefaults.height)
        .task {
            await self.model.loadDevices()
            // Parks here until the view disappears: SwiftUI cancels the task, which
            // terminates the device-change stream and tears down its observer.
            await self.model.observeDeviceChanges()
        }
        .task { await self.model.subscribeToDisplayChanges() }
        // Post-stop alerts: surface on re-appear or on async flag changes.
        // `.onAppear` covers the case where the flag is already set when the main window
        // re-mounts (stop() sets the flag before opening the main window). `.onChange`
        // covers any later asynchronous transition.
        // Write-error supersedes degraded-warning (both can be true simultaneously when
        // the writer fails under heavy backpressure). Priority is enforced in `resolvedAlert`.
        .onAppear {
            // Guard prevents a repeated appear (e.g. window re-focus) from overwriting an active alert.
            if self.pendingAlert == nil {
                self.pendingAlert = self.resolvedAlert()
            }
            // Install menu-bar record intent while the main window is visible (#38).
            // [weak model] prevents a retain cycle: coordinator ← closure ← model,
            // while model also holds coordinator.
            let model = self.model
            self.model.coordinator.menuBarRecordIntent = { [weak model] in
                guard let model else {
                    mainViewLogger.error("menuBarRecordIntent fired but MainViewModel deallocated — no-op")
                    return
                }
                Task { await model.record() }
            }
        }
        .onDisappear {
            // Clear the seam when the main window dismounts so the menu bar falls back
            // to «открыть main window» when no window is showing (origin = .menuBar).
            self.model.coordinator.menuBarRecordIntent = nil
        }
        .onChange(of: self.model.coordinator.lastWriteError) { _, _ in
            if let alert = self.resolvedAlert() {
                self.pendingAlert = alert
            }
        }
        .alert(item: self.$pendingAlert) { alert in
            self.makeAlert(for: alert)
        }
        // Output-directory validation alert: shown when `record()` rejects a missing or
        // non-writable output folder. Bound directly to `model.outputDirectoryError` so
        // repeated clicks with the same error message reliably re-show the alert — an
        // intermediate @State copy would miss re-triggers when Observable batches a
        // nil→value mutation within a single synchronous block (old == new for onChange).
        .alert(
            "Папка для записи недоступна",
            isPresented: Binding(
                get: { self.model.outputDirectoryError != nil },
                set: {
                    if !$0 {
                        self.model.outputDirectoryError = nil
                    }
                }
            )
        ) {
            Button("ОК") { self.model.outputDirectoryError = nil }
        } message: {
            if let message = self.model.outputDirectoryError {
                Text(message)
            }
        }
    }

    // MARK: - No permissions empty state (AC-2d)

    private var noPermissionsView: some View {
        VStack(spacing: Metrics.noPermissionsSpacing) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Metrics.emptyIconSize))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Запись недоступна")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Выдайте разрешения на запись экрана или камеру, чтобы начать.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.noPermissionsTextPaddingH)
            Button("Вернуться к разрешениям") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Вернуться к разрешениям")
            Spacer()
        }
        .padding(.horizontal, Metrics.outerPaddingH)
    }

    // MARK: - Main content

    var mainContent: some View {
        // Sticky-footer layout: sections scroll freely; the primary CTA stays pinned at the bottom
        // so it is always visible regardless of Dynamic Type size (issue #136).
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Metrics.sectionSpacing) {
                    self.screenSection
                    self.cameraSection
                    self.microphoneSection
                    self.outputSection
                }
                .padding(.horizontal, Metrics.outerPaddingH)
                .padding(.vertical, Metrics.outerPaddingV)
            }
            self.stickyFooter
        }
        // Menu-bar-first app: ⌘, only fires when Onset is frontmost, so the config screen
        // needs a visible way into Settings. `SettingsLink` opens the Settings scene without
        // an @Environment(\.openSettings) seam. The toolbar lives in the window title bar
        // (chrome), so it does not consume the fixed `.contentSize` content frame.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
                .help("Настройки")
            }
        }
    }

    /// The sticky footer: record button + optional reason/error text.
    ///
    /// Lives outside the `ScrollView` so the primary CTA is visible at any Dynamic Type size.
    private var stickyFooter: some View {
        VStack(spacing: Metrics.footerBottomPad) {
            self.recordButton
            self.recordFooter
        }
        .padding(.horizontal, Metrics.outerPaddingH)
        .padding(.bottom, Metrics.outerPaddingV)
    }

    // MARK: - Record footer (reason / error)

    @ViewBuilder
    private var recordFooter: some View {
        if let reason = self.model.recordDisabledReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel(reason)
        }
        if let error = self.model.recordError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Record button

    var recordButton: some View {
        Button {
            Task { await self.model.record() }
        } label: {
            self.recordButtonLabel
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.recordButtonHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!self.model.canRecord || self.model.isStartingRecording)
        .accessibilityLabel(
            self.model.isRecordingWithoutAudio
                ? "Записать без звука"
                : "Записать"
        )
        .accessibilityHint(self.model.recordDisabledReason ?? "")
        .accessibilityIdentifier("record-button")
    }

    private var recordButtonLabel: some View {
        HStack(spacing: Metrics.recordButtonHSpacing) {
            if self.model.isStartingRecording {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color.white)
                    .frame(width: Metrics.recordButtonDotSize, height: Metrics.recordButtonDotSize)
                    .accessibilityHidden(true)
            }
            Text(self.model.isStartingRecording ? "Запуск…" : "Записать")
                .fontWeight(.semibold)
            if self.model.isRecordingWithoutAudio {
                Text("без звука")
                    .font(.caption)
                    .opacity(Metrics.recordButtonWithoutAudioOpacity)
            }
        }
    }
}

// MARK: - MainView — Alert resolution

extension MainView {
    /// Returns the highest-priority pending alert, or `nil` when no alert is due.
    /// Write-error supersedes degraded-warning when both flags are set simultaneously.
    private func resolvedAlert() -> PostStopAlert? {
        PostStopAlert.resolve(writeError: self.model.coordinator.lastWriteError)
    }

    /// Builds the `Alert` for a given `PostStopAlert` case.
    private func makeAlert(for alert: PostStopAlert) -> Alert {
        switch alert {
        case let .writeError(reason):
            Alert(
                title: Text("Не удалось сохранить запись"),
                message: Text(reason),
                dismissButton: .default(Text("ОК")) {
                    self.model.coordinator.acknowledgeWriteError()
                    // Re-resolve after acknowledge: returns nil now that the write error is cleared.
                    self.pendingAlert = self.resolvedAlert()
                }
            )
        }
    }
}

// MARK: - SectionCard

// Metrics as module-level lets: static stored properties are not supported in generic types.
let sectionCardHeaderSpacing: CGFloat = 6
let sectionCardPadding: CGFloat = 14
let sectionCardCornerRadius: CGFloat = 10
let sectionCardTitleKerning: CGFloat = 0.5

/// Reusable card container for a labeled settings section.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: sectionCardHeaderSpacing) {
            Text(self.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(sectionCardTitleKerning)

            VStack(alignment: .leading, spacing: 0) {
                self.content()
            }
            .padding(sectionCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: sectionCardCornerRadius))
        }
    }
}

// MARK: - CameraPreviewRepresentable

/// `NSViewRepresentable` wrapper for `CameraPreviewView`.
///
/// `CameraPreviewView.init` wires the `AVCaptureVideoPreviewLayer`; the device-change recreation
/// is forced by toggling `.id(model.previewGeneration)` on the call site. `updateNSView` is the
/// SOLE writer of the preview connection's `isVideoMirrored`: driven by `cameraMirror` (observed
/// from `AppSettings`), it flips the preview live as a cheap layer transform — no session
/// reconfiguration, no `CameraSource` rebuild, no flicker.
struct CameraPreviewRepresentable: NSViewRepresentable {
    let sessionHandle: SessionHandle?

    /// Whether the live preview is horizontally mirrored. Sourced from `AppSettings.cameraMirror`
    /// at the call site so SwiftUI re-invokes `updateNSView` when the toggle changes.
    let cameraMirror: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(sessionHandle: self.sessionHandle)
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        // Sole writer of the preview connection's mirror state. The layer itself is wired in
        // CameraPreviewView.init (which also disables automatic mirroring); device changes are
        // handled by .id()-driven recreation at the call site.
        // isVideoMirroringSupported guard mirrors the recording path (applyRecordingMirror).
        guard let connection = nsView.previewLayer?.connection, connection.isVideoMirroringSupported else {
            return
        }
        // updateNSView runs on every SwiftUI pass (device discovery, permission/hover/state churn);
        // only touch the connection when the value actually differs to avoid redundant writes.
        guard connection.isVideoMirrored != self.cameraMirror else {
            return
        }
        connection.isVideoMirrored = self.cameraMirror
    }
}
