import AppKit
import SwiftUI

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

    /// Drives the AC-9 degraded-warning alert. Set when `coordinator.lastDegradedWarning`
    /// becomes true (either via `.onChange` or on re-appear after stop).
    @State private var showDegradedAlert = false

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
        // AC-9: surface degraded-recording warning on return to main window.
        // `.onAppear` covers the case where the flag is already set when the main window
        // re-mounts (stop() sets the flag before opening the main window). `.onChange`
        // covers any later asynchronous transition.
        .onAppear {
            if self.model.coordinator.lastDegradedWarning {
                self.showDegradedAlert = true
            }
        }
        .onChange(of: self.model.coordinator.lastDegradedWarning) { _, newValue in
            if newValue {
                self.showDegradedAlert = true
            }
        }
        .alert("Запись завершена с ошибками", isPresented: self.$showDegradedAlert) {
            Button("ОК") {
                self.model.coordinator.acknowledgeDegradedWarning()
                self.showDegradedAlert = false
            }
        } message: {
            Text("Во время записи были пропущены кадры из-за перегрузки диска. Видеофайл может содержать пропуски.")
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
