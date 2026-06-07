import AppKit
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
        static let windowMinWidth: CGFloat = 460
        static let windowMinHeight: CGFloat = 560
        static let outerPaddingH: CGFloat = 20
        static let outerPaddingV: CGFloat = 16
        static let sectionSpacing: CGFloat = 12
        static let previewHeight: CGFloat = 130
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
    }

    // MARK: - Dependencies

    @Bindable var model: MainViewModel

    /// Called when the user wants to return to onboarding.
    let onReturnToOnboarding: () -> Void

    // MARK: - State

    /// Drives the post-stop alert. Write-error supersedes degraded-warning: when both are set,
    /// only the write-error alert fires (the file was not saved — higher severity).
    /// Using `alert(item:)` with an enum enforces the priority ordering and avoids two
    /// simultaneous `isPresented` bindings competing for the same presentation slot.
    @State private var pendingAlert: PostStopAlert?

    // MARK: - Body

    var body: some View {
        Group {
            if self.model.showNoPermissionsState {
                self.noPermissionsView
            } else {
                self.mainContent
            }
        }
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        .task {
            await self.model.loadDevices()
        }
        // Post-stop alerts: surface on re-appear or on async flag changes.
        // `.onAppear` covers the case where the flag is already set when the main window
        // re-mounts (stop() sets the flag before opening the main window). `.onChange`
        // covers any later asynchronous transition.
        // Write-error supersedes degraded-warning (both can be true simultaneously when
        // the writer fails under heavy backpressure). Priority is enforced in `resolvedAlert`.
        .onAppear {
            self.pendingAlert = self.resolvedAlert()
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
        .onChange(of: self.model.coordinator.lastDegradedWarning) { _, newValue in
            if newValue, self.pendingAlert == nil {
                self.pendingAlert = self.resolvedAlert()
            }
        }
        .alert(item: self.$pendingAlert) { alert in
            self.makeAlert(for: alert)
        }
    }

    // MARK: - Alert resolution

    /// Returns the highest-priority pending alert, or `nil` when no alert is due.
    /// Write-error supersedes degraded-warning when both flags are set simultaneously.
    private func resolvedAlert() -> PostStopAlert? {
        PostStopAlert.resolve(
            writeError: self.model.coordinator.lastWriteError,
            degraded: self.model.coordinator.lastDegradedWarning,
            droppedFrames: self.model.coordinator.drops.encoderBackpressureDrops
        )
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
                    self.pendingAlert = nil
                }
            )

        case let .degradedWarning(droppedFrames):
            Alert(
                title: Text("Запись завершена"),
                message: Text(RussianPluralForm.droppedFrames(count: droppedFrames)),
                dismissButton: .default(Text("ОК")) {
                    self.model.coordinator.acknowledgeDegradedWarning()
                    self.pendingAlert = nil
                }
            )
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
        ScrollView {
            VStack(spacing: Metrics.sectionSpacing) {
                self.screenSection
                self.cameraSection
                self.microphoneSection
                Spacer(minLength: Metrics.footerBottomPad)
                self.recordButton
                self.recordFooter
            }
            .padding(.horizontal, Metrics.outerPaddingH)
            .padding(.vertical, Metrics.outerPaddingV)
        }
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
                .frame(height: Metrics.recordButtonHeight)
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

// MARK: - SectionCard

// Metrics as module-level lets: static stored properties are not supported in generic types.
let sectionCardHeaderSpacing: CGFloat = 6
let sectionCardPadding: CGFloat = 14
let sectionCardCornerRadius: CGFloat = 10
let sectionCardTitleKerning: CGFloat = 0.5

/// Reusable card container for a labeled settings section.
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

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
/// `CameraPreviewView.init` wires the `AVCaptureVideoPreviewLayer`; `updateNSView` is a no-op
/// by design. Force recreation by toggling `.id(model.previewGeneration)` on the call site.
struct CameraPreviewRepresentable: NSViewRepresentable {
    let sessionHandle: SessionHandle?

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(sessionHandle: self.sessionHandle)
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        // No-op: CameraPreviewView wires the layer in init.
        // Caller must use .id() to force recreation when sessionHandle changes.
    }
}

// MARK: - PostStopAlert

/// Which post-stop alert `MainView` presents after a recording ends.
///
/// `writeError` carries the localized reason for the message body.
/// `degradedWarning` carries the session's encoder-backpressure drop count so the alert can
/// display "Пропущено N кадров — возможны рывки." (AC-9).
///
/// Priority ordering is enforced by `resolve(writeError:degraded:droppedFrames:)`: write-error
/// supersedes degraded-warning because a failed write means the file was not saved (higher severity).
enum PostStopAlert: Identifiable {
    case writeError(reason: String)
    /// Post-stop warning shown when the session's encoder-backpressure drop count exceeds zero.
    ///
    /// `droppedFrames` is `RecordingResult.drops.encoderBackpressureDrops` captured at stop time.
    /// The value is frozen — `RecordingCoordinator.drops` resets only on the next `start()`, so
    /// reading it before `acknowledgeDegradedWarning()` is safe.
    case degradedWarning(droppedFrames: Int)

    var id: String {
        switch self {
        case .writeError: "writeError"
        case .degradedWarning: "degradedWarning"
        }
    }

    /// Returns the highest-priority alert given the coordinator state, or `nil` when no alert is due.
    ///
    /// Priority: `.writeError` > `.degradedWarning` > `nil`.
    /// Both flags can be simultaneously true when the writer fails under heavy backpressure;
    /// only the higher-severity alert is shown to avoid competing presentation slots.
    ///
    /// - Parameters:
    ///   - writeError:    Human-readable write-failure reason, or `nil` when the file was saved.
    ///   - degraded:      `true` when the finished session had encoder-backpressure drops.
    ///   - droppedFrames: `RecordingResult.drops.encoderBackpressureDrops` at stop time.
    nonisolated static func resolve(writeError: String?, degraded: Bool, droppedFrames: Int) -> Self? {
        if let reason = writeError {
            return .writeError(reason: reason)
        }
        if degraded {
            return .degradedWarning(droppedFrames: droppedFrames)
        }
        return nil
    }
}
