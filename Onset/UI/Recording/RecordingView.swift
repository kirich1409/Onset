// swiftlint:disable trailing_closure
// Rationale: `Button(action:label:)` with explicit `label:` reads clearer than trailing-closure
// syntax here; matches the convention in RecordingCoordinatorTests. Re-enabled at end of file.
// swiftlint:disable file_length
// Rationale: view + mapper + 5 previews naturally exceed 400 lines; splitting them across files
// would obscure the one-to-one relationship between the mapper and the view that uses it.

import os
import SwiftUI

// MARK: - Logger

nonisolated private let recordingLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "RecordingView"
)

// MARK: - RecordingView

/// The recording-in-progress window (AC-3, AC-8, AC-9).
///
/// A thin wrapper that reads the `RecordingCoordinator`'s published state and forwards it to
/// the layout-only `RecordingContentView`. The coordinator is the *sole* state owner — this view
/// reads but never subscribes independently or owns its own timer.
///
/// Since #242 (menu-bar-first), recording starts without opening this window. The window is
/// opened on demand via «Открыть окно записи» in the menu bar. The title-bar red button now
/// **hides** the window rather than stopping the recording — closing the window no longer
/// implies stopping. Cmd-Q graceful termination is tracked in #243.
struct RecordingView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        RecordingContentView(
            state: self.coordinator.recordingState,
            elapsed: self.coordinator.elapsed,
            checklist: self.coordinator.checklist,
            sourceLiveness: self.coordinator.sourceLiveness,
            onStop: {
                recordingLogger.info("Stop requested via RecordingView button")
                Task { await self.coordinator.stop() }
            }
        )
        // No .onDisappear → stop() since #242: closing the recording window no longer stops
        // the recording. The window is opened on demand and the red button simply hides it.
        // Graceful Cmd-Q handling (applicationShouldTerminate / willTerminate await-stop) is
        // tracked in #243.
    }
}

// MARK: - RecordingContentView

/// Pure layout view for the recording-in-progress window.
///
/// All inputs are value types — no coordinator reference, no I/O. This makes the view
/// trivially previewable and all display-logic paths unit-testable via `RecordingDisplayMapper`.
struct RecordingContentView: View {
    private enum Metrics {
        // Layout — static: not Dynamic-Type-scaled
        static let outerPadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 0
        static let statusSpacing: CGFloat = 4
        static let statusBottomPadding: CGFloat = 8
        static let timerBottomPadding: CGFloat = 8
        static let checklistTopDividerTopPadding: CGFloat = 12
        static let checklistRowHPadding: CGFloat = 16
        static let checklistRowVPadding: CGFloat = 10
        static let stopButtonTopPadding: CGFloat = 12
        static let stopButtonBottomPadding: CGFloat = 8
        static let stopButtonHeight: CGFloat = 44
        static let stopButtonCornerRadius: CGFloat = 10
        static let stopButtonIconSpacing: CGFloat = 6
        static let statusDotSize: CGFloat = 8
        static let footerSpacing: CGFloat = 4
    }

    /// Typography — `@ScaledMetric`: scales with the system Dynamic Type setting (issue #136).
    /// `@ScaledMetric` cannot be static, so typography values live as instance properties here
    /// rather than in the `Metrics` enum.
    @ScaledMetric(relativeTo: .body)
    private var statusFontSize: CGFloat = 13
    /// The timer is large by design; scaling relative to .largeTitle preserves its visual
    /// weight across Dynamic Type sizes while still responding to accessibility preferences.
    @ScaledMetric(relativeTo: .largeTitle)
    private var timerFontSize: CGFloat = 56
    @ScaledMetric(relativeTo: .body)
    private var checklistLabelFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption)
    private var checklistCheckmarkFontSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption)
    private var stopButtonIconFontSize: CGFloat = 12
    @ScaledMetric(relativeTo: .callout)
    private var stopButtonLabelFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2)
    private var footerFontSize: CGFloat = 11

    let state: RecordingState
    let elapsed: Int
    let checklist: RecordingChecklist
    let sourceLiveness: SourceLiveness
    let onStop: () -> Void

    var body: some View {
        // Sticky-footer layout: scrollable content + pinned stop button (issue #136).
        // The stop button stays outside the ScrollView so it is always reachable even when
        // content overflows at a large Dynamic Type size. macOS auto-hides scrollbars, so
        // relying on scroll-to-reach for a critical CTA is not acceptable.
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Metrics.sectionSpacing) {
                    self.statusSection
                    self.timerSection
                    Divider()
                        .padding(.top, Metrics.checklistTopDividerTopPadding)
                    self.checklistSection
                }
                .padding(Metrics.outerPadding)
            }
            // Stop button + footer pinned below the scroll area — always visible.
            VStack(spacing: 0) {
                self.stopButtonSection
                self.footerSection
            }
            .padding(.horizontal, Metrics.outerPadding)
            .padding(.bottom, Metrics.outerPadding)
        }
        // Fixed size matching the window scene's .windowResizability(.contentSize).
        // alignment: .top pins the content to the top edge when content is shorter than the window.
        .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight, alignment: .top)
    }

    // MARK: Status section

    private var statusSection: some View {
        HStack(spacing: Metrics.statusSpacing) {
            Circle()
                .fill(RecordingDisplayMapper.dotColor(for: self.state))
                .frame(width: Metrics.statusDotSize, height: Metrics.statusDotSize)
            Text(RecordingDisplayMapper.statusText(for: self.state))
                .font(.system(size: self.statusFontSize, weight: .semibold))
                .foregroundStyle(RecordingDisplayMapper.statusTextColor(for: self.state))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Metrics.statusBottomPadding)
    }

    // MARK: Timer section

    private var timerSection: some View {
        Text(ElapsedFormatter.string(from: self.elapsed))
            .font(.system(size: self.timerFontSize, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Metrics.timerBottomPadding)
            .accessibilityLabel("Время записи \(ElapsedFormatter.string(from: self.elapsed))")
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Checklist section

    @ViewBuilder
    private var checklistSection: some View {
        if let screenDesc = self.checklist.screenDescription {
            self.checklistRow(
                label: "Экран",
                value: screenDesc,
                isLive: self.sourceLiveness.screen,
                gender: .masculine
            )
        }
        if let cameraDesc = self.checklist.cameraDescription {
            self.checklistRow(
                label: "Камера",
                value: cameraDesc,
                isLive: self.sourceLiveness.camera,
                gender: .feminine
            )
        }
        if let micDesc = self.checklist.microphoneDescription {
            self.checklistRow(
                label: "Микрофон",
                value: micDesc,
                isLive: self.sourceLiveness.microphone,
                gender: .masculine
            )
        }
    }

    @ViewBuilder
    private func checklistRow(
        label: String,
        value: String,
        isLive: Bool,
        gender: SourceGender
    )
    -> some View {
        let rowLabel = RecordingDisplayMapper.checklistRowAccessibilityLabel(
            label: label,
            value: value,
            isLive: isLive,
            gender: gender
        )
        HStack {
            Text(label)
                .font(.system(size: self.checklistLabelFontSize))
                .foregroundStyle(.primary)
            Spacer()
            Text(RecordingDisplayMapper.checklistRowValueText(value: value, isLive: isLive, gender: gender))
                .font(.system(size: self.checklistLabelFontSize))
                .foregroundStyle(.secondary)
            Image(systemName: RecordingDisplayMapper.checklistRowIcon(isLive: isLive))
                .font(.system(size: self.checklistCheckmarkFontSize, weight: .semibold))
                .foregroundStyle(RecordingDisplayMapper.checklistRowIconColor(isLive: isLive))
        }
        .padding(.horizontal, Metrics.checklistRowHPadding)
        .padding(.vertical, Metrics.checklistRowVPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel)
        Divider()
    }

    // MARK: Stop button section

    private var stopButtonSection: some View {
        Button(
            action: self.onStop,
            label: {
                HStack(spacing: Metrics.stopButtonIconSpacing) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: self.stopButtonIconFontSize, weight: .semibold))
                    Text("Остановить")
                        .font(.system(size: self.stopButtonLabelFontSize, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.stopButtonHeight)
                .foregroundStyle(Color.white)
                .background(Color("StopButtonBackground"))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.stopButtonCornerRadius))
            }
        )
        .buttonStyle(.plain)
        .padding(.top, Metrics.stopButtonTopPadding)
        .padding(.bottom, Metrics.stopButtonBottomPadding)
    }
}

// MARK: - RecordingContentView footer section

extension RecordingContentView {
    // MARK: Footer section

    private var footerSection: some View {
        HStack(spacing: Metrics.footerSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: self.footerFontSize))
                .foregroundStyle(.secondary)
            Text("Настройки недоступны во время записи — глобальный hotkey")
                .font(.system(size: self.footerFontSize))
                .foregroundStyle(.secondary)
            Text("⌘⌥⌃R")
                .font(.system(size: self.footerFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

// MARK: - SourceGender

/// Grammatical gender of a source label used to produce correct Russian state words.
///
/// Russian adjectives and short forms agree with the grammatical gender of the noun they modify.
/// Экран and Микрофон are masculine; Камера is feminine.
nonisolated enum SourceGender {
    case masculine
    case feminine
}

// MARK: - RecordingDisplayMapper

/// Pure static mappers from recording state to display values.
///
/// Extracted here so they can be tested directly without rendering a SwiftUI view.
nonisolated enum RecordingDisplayMapper {
    // MARK: Status row

    /// The status label text.
    ///
    /// - Normal: «ИДЁТ ЗАПИСЬ»
    /// - Degraded: «ЗАПИСЬ · ДЕГРАДАЦИЯ»
    static func statusText(for state: RecordingState) -> String {
        switch state {
        case .normal: "ИДЁТ ЗАПИСЬ"
        case .degraded: "ЗАПИСЬ · ДЕГРАДАЦИЯ"
        }
    }

    /// Color of the recording dot (always red — both normal and degraded per mockup).
    static func dotColor(for state: RecordingState) -> Color {
        switch state {
        case .normal, .degraded: .red
        }
    }

    /// Color of the status label text.
    ///
    /// - Normal: red (matches the dot)
    /// - Degraded: orange (draws attention to degraded state while dot stays red)
    static func statusTextColor(for state: RecordingState) -> Color {
        switch state {
        case .normal: .red
        case .degraded: .orange
        }
    }

    // MARK: Checklist row liveness (#39 / AC-12)

    /// SF Symbol name for the checklist row status icon.
    ///
    /// - Live: «checkmark» (green, source is recording).
    /// - Revoked: «xmark» (red, source was stopped by a graceful revoke).
    static func checklistRowIcon(isLive: Bool) -> String {
        isLive ? "checkmark" : "xmark"
    }

    /// Color of the checklist row status icon.
    ///
    /// - Live: green.
    /// - Revoked: red (matches the danger/stopped semantic; avoids equality ambiguity of `.secondary`).
    static func checklistRowIconColor(isLive: Bool) -> Color {
        isLive ? .green : .red
    }

    /// The Russian state word for a source, agreeing with its grammatical gender.
    ///
    /// - Live masculine: «активен» (Экран, Микрофон).
    /// - Live feminine: «активна» (Камера).
    /// - Revoked masculine: «остановлен».
    /// - Revoked feminine: «остановлена».
    static func stateWord(isLive: Bool, gender: SourceGender) -> String {
        switch (isLive, gender) {
        case (true, .masculine): "активен"
        case (true, .feminine): "активна"
        case (false, .masculine): "остановлен"
        case (false, .feminine): "остановлена"
        }
    }

    /// Display text for the checklist row value.
    ///
    /// - Live: returns `value` unchanged.
    /// - Revoked: appends «· <state>» with the correct gendered form to signal the source stopped
    ///   mid-recording (e.g. «MX Brio · 1920×1080 · остановлена» for a feminine source).
    static func checklistRowValueText(value: String, isLive: Bool, gender: SourceGender) -> String {
        isLive ? value : "\(value) · \(self.stateWord(isLive: false, gender: gender))"
    }

    /// Accessibility label for a checklist row that folds name, device value, and state into one
    /// announcement so VoiceOver users hear which source is recording and in what state.
    ///
    /// Format: «<label> — <value> — <state>», e.g. «Камера — MX Brio · 1920×1080 — активна».
    ///
    /// The raw `value` is used (not the visible suffixed text) to avoid duplicating the state word.
    static func checklistRowAccessibilityLabel(
        label: String,
        value: String,
        isLive: Bool,
        gender: SourceGender
    )
    -> String {
        "\(label) — \(value) — \(self.stateWord(isLive: isLive, gender: gender))"
    }
}

// MARK: - Previews

#Preview("Normal — Light") {
    RecordingContentView(
        state: .normal,
        elapsed: 257,
        checklist: .init(
            screenDescription: "3840×2160 @ 60 Гц",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .allLive,
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.light)
}

#Preview("Normal — Dark") {
    RecordingContentView(
        state: .normal,
        elapsed: 257,
        checklist: .init(
            screenDescription: "3840×2160 @ 60 Гц",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .allLive,
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.dark)
}

#Preview("Degraded — Dark") {
    RecordingContentView(
        state: .degraded,
        elapsed: 257,
        checklist: .init(
            screenDescription: "3840×2160 @ 60 Гц",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .allLive,
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.dark)
}

#Preview("Screen only — Light") {
    RecordingContentView(
        state: .normal,
        elapsed: 0,
        checklist: .init(
            screenDescription: "2560×1440 @ 60 Гц",
            cameraDescription: nil,
            microphoneDescription: nil
        ),
        sourceLiveness: .allLive,
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.light)
}

#Preview("Camera revoked — Dark") {
    RecordingContentView(
        state: .normal,
        elapsed: 312,
        checklist: .init(
            screenDescription: "3840×2160 @ 60 Гц",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .init(screen: true, camera: false, microphone: false),
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.dark)
}

#Preview("Large font — Dynamic Type accessibility5 (issue #136)") {
    RecordingContentView(
        state: .normal,
        elapsed: 257,
        checklist: .init(
            screenDescription: "3840×2160 @ 60 Гц",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .allLive,
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .dynamicTypeSize(.accessibility5)
}

// swiftlint:enable trailing_closure
