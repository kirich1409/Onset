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
/// Title-bar close is intercepted via `.onDisappear`: when the window vanishes while recording is
/// still active, the coordinator's `stop()` is called. The coordinator's `isStopping` guard makes
/// the double-call safe (Stop button also dismisses the window — the second call is a no-op).
struct RecordingView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        RecordingContentView(
            state: self.coordinator.recordingState,
            elapsed: self.coordinator.elapsed,
            drops: self.coordinator.drops,
            checklist: self.coordinator.checklist,
            sourceLiveness: self.coordinator.sourceLiveness,
            onStop: {
                recordingLogger.info("Stop requested via RecordingView button")
                Task { await self.coordinator.stop() }
            }
        )
        // Intercept the title-bar red-button close: when the window disappears while a
        // recording is still in progress, trigger stop(). The coordinator's `isStopping` guard
        // makes this idempotent if the Stop button was also tapped (which dismisses the window,
        // firing this observer as a second call — stop() exits early on the re-entrant path).
        //
        // Best-effort: on abrupt Cmd-Q the system may tear down this detached Task before
        // session.stop() fully finalises the file. This is not a regression — the prior
        // placeholder had no stop-on-close at all, and any partially-written file remains
        // recoverable via the movieFragmentInterval fragment headers written mid-recording
        // (AC-10). Proper applicationShouldTerminate / willTerminate await-stop handling
        // is deferred to #38.
        .onDisappear {
                if self.coordinator.phase == .recording {
                    recordingLogger.info("Recording window dismissed while recording — triggering stop")
                    Task { await self.coordinator.stop() }
                }
            }
    }
}

// MARK: - RecordingContentView

/// Pure layout view for the recording-in-progress window.
///
/// All inputs are value types — no coordinator reference, no I/O. This makes the view
/// trivially previewable and all display-logic paths unit-testable via `RecordingDisplayMapper`.
struct RecordingContentView: View {
    private enum Metrics {
        // Layout
        static let outerPadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 0
        static let statusSpacing: CGFloat = 4
        static let statusBottomPadding: CGFloat = 8
        static let timerBottomPadding: CGFloat = 8
        static let pillDotSize: CGFloat = 6
        static let pillDotSpacing: CGFloat = 4
        static let pillHPadding: CGFloat = 12
        static let pillVPadding: CGFloat = 5
        static let pillBottomPadding: CGFloat = 8
        static let checklistTopDividerTopPadding: CGFloat = 12
        static let checklistRowHPadding: CGFloat = 16
        static let checklistRowVPadding: CGFloat = 10
        static let stopButtonTopPadding: CGFloat = 12
        static let stopButtonBottomPadding: CGFloat = 8
        static let stopButtonHeight: CGFloat = 44
        static let stopButtonCornerRadius: CGFloat = 10
        static let stopButtonIconSpacing: CGFloat = 6
        static let statusDotSize: CGFloat = 8

        // Typography
        static let statusFontSize: CGFloat = 13
        static let timerFontSize: CGFloat = 56
        static let pillFontSize: CGFloat = 12
        static let checklistLabelFontSize: CGFloat = 13
        static let checklistCheckmarkFontSize: CGFloat = 11
        static let stopButtonIconFontSize: CGFloat = 12
        static let stopButtonLabelFontSize: CGFloat = 14
        static let footerFontSize: CGFloat = 11
        static let footerSpacing: CGFloat = 4
    }

    let state: RecordingState
    let elapsed: Int
    let drops: DropCounters
    let checklist: RecordingChecklist
    let sourceLiveness: SourceLiveness
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: Metrics.sectionSpacing) {
            self.statusSection
            self.timerSection
            self.dropPillSection
            Divider()
                .padding(.top, Metrics.checklistTopDividerTopPadding)
            self.checklistSection
            self.stopButtonSection
            self.footerSection
        }
        .padding(Metrics.outerPadding)
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
                .font(.system(size: Metrics.statusFontSize, weight: .semibold))
                .foregroundStyle(RecordingDisplayMapper.statusTextColor(for: self.state))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Metrics.statusBottomPadding)
    }

    // MARK: Timer section

    private var timerSection: some View {
        Text(ElapsedFormatter.string(from: self.elapsed))
            .font(.system(size: Metrics.timerFontSize, weight: .regular, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Metrics.timerBottomPadding)
            .accessibilityLabel("Время записи \(ElapsedFormatter.string(from: self.elapsed))")
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Drop pill section

    @ViewBuilder private var dropPillSection: some View {
        let pillLabel = RecordingDisplayMapper.pillAccessibilityLabel(state: self.state, drops: self.drops)
        HStack(spacing: Metrics.pillDotSpacing) {
            Circle()
                .fill(RecordingDisplayMapper.pillDotColor(for: self.state))
                .frame(width: Metrics.pillDotSize, height: Metrics.pillDotSize)
            Text(RecordingDisplayMapper.pillText(state: self.state, drops: self.drops))
                .font(.system(size: Metrics.pillFontSize))
                .foregroundStyle(RecordingDisplayMapper.pillTextColor(for: self.state))
                .accessibilityLabel(pillLabel)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .padding(.horizontal, Metrics.pillHPadding)
        .padding(.vertical, Metrics.pillVPadding)
        .background(RecordingDisplayMapper.pillBackground(for: self.state))
        .clipShape(Capsule())
        .padding(.bottom, Metrics.pillBottomPadding)
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
                .font(.system(size: Metrics.checklistLabelFontSize))
                .foregroundStyle(.primary)
            Spacer()
            Text(RecordingDisplayMapper.checklistRowValueText(value: value, isLive: isLive, gender: gender))
                .font(.system(size: Metrics.checklistLabelFontSize))
                .foregroundStyle(.secondary)
            Image(systemName: RecordingDisplayMapper.checklistRowIcon(isLive: isLive))
                .font(.system(size: Metrics.checklistCheckmarkFontSize, weight: .semibold))
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
                        .font(.system(size: Metrics.stopButtonIconFontSize, weight: .semibold))
                    Text("Остановить")
                        .font(.system(size: Metrics.stopButtonLabelFontSize, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.stopButtonHeight)
                .foregroundStyle(Color.white)
                .background(Color("StopButtonBackground"))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.stopButtonCornerRadius))
            }
        )
        .buttonStyle(.plain)
        .padding(.top, Metrics.stopButtonTopPadding)
        .padding(.bottom, Metrics.stopButtonBottomPadding)
    }

    // MARK: Footer section

    private var footerSection: some View {
        HStack(spacing: Metrics.footerSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: Metrics.footerFontSize))
                .foregroundStyle(.secondary)
            Text("Настройки недоступны во время записи — глобальный hotkey")
                .font(.system(size: Metrics.footerFontSize))
                .foregroundStyle(.secondary)
            Text("⌘⌥⌃R")
                .font(.system(size: Metrics.footerFontSize, weight: .semibold))
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

    // MARK: Drop pill

    /// The full pill text, with correct Russian pluralization.
    ///
    /// - Normal: «1 пропущенный кадр» / «2 пропущенных кадра» / «5 пропущенных кадров»
    ///   (where N = encoderBackpressureDrops)
    /// - Degraded: «Пропущен 1 кадр» / «Пропущено 2 кадра» / «Пропущено 5 кадров»
    ///   (where N = encoderBackpressureDrops; no disk attribution — `DropCounters` carries no reason)
    static func pillText(state: RecordingState, drops: DropCounters) -> String {
        let count = drops.encoderBackpressureDrops
        switch state {
        case .normal:
            let adjective = RussianPluralForm.select(
                count: count,
                one: "пропущенный",
                few: "пропущенных",
                many: "пропущенных"
            )
            let noun = RussianPluralForm.select(count: count, one: "кадр", few: "кадра", many: "кадров")
            return "\(count) \(adjective) \(noun)"

        case .degraded:
            let verb = RussianPluralForm.select(
                count: count,
                one: "Пропущен",
                few: "Пропущено",
                many: "Пропущено"
            )
            let noun = RussianPluralForm.select(count: count, one: "кадр", few: "кадра", many: "кадров")
            return "\(verb) \(count) \(noun)"
        }
    }

    /// Accessibility label for the drop-pill element.
    ///
    /// Returns «Нет пропущенных кадров» when the encoder-backpressure drop counter is zero.
    /// Otherwise delegates to `pillText(state:drops:)` so visual and accessibility labels match.
    static func pillAccessibilityLabel(state: RecordingState, drops: DropCounters) -> String {
        guard drops.encoderBackpressureDrops > 0 else { return "Нет пропущенных кадров" }
        return self.pillText(state: state, drops: drops)
    }

    /// Color of the small dot inside the pill.
    static func pillDotColor(for state: RecordingState) -> Color {
        switch state {
        case .normal: .secondary
        case .degraded: .orange
        }
    }

    /// Color of the pill text.
    static func pillTextColor(for state: RecordingState) -> Color {
        switch state {
        case .normal: .secondary
        case .degraded: .white
        }
    }

    /// Background shape fill of the pill.
    static func pillBackground(for state: RecordingState) -> Color {
        switch state {
        case .normal: Color.secondary.opacity(self.normalPillOpacity)
        case .degraded: .orange
        }
    }

    /// Opacity of the pill background in the normal (non-degraded) state.
    ///
    /// A subtle overlay matching the macOS secondary-label color at low opacity.
    static let normalPillOpacity = 0.15

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
        drops: .init(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        checklist: .init(
            screenDescription: "3840×2160",
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
        drops: .init(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        checklist: .init(
            screenDescription: "3840×2160",
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
        drops: .init(encoderBackpressureDrops: 128, captureDrops: 0, cfrNormalizationDrops: 0),
        checklist: .init(
            screenDescription: "3840×2160",
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
        drops: .init(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        checklist: .init(
            screenDescription: "2560×1440",
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
        drops: .init(encoderBackpressureDrops: 0, captureDrops: 0, cfrNormalizationDrops: 0),
        checklist: .init(
            screenDescription: "3840×2160",
            cameraDescription: "MX Brio · 1920×1080",
            microphoneDescription: "MacBook Pro"
        ),
        sourceLiveness: .init(screen: true, camera: false, microphone: false),
        onStop: {}
    )
    .frame(width: WindowDefaults.recordingWidth, height: WindowDefaults.recordingHeight)
    .preferredColorScheme(.dark)
}

// swiftlint:enable trailing_closure
