import SwiftUI

// MARK: - MainView — No permissions empty state (AC-2d)

extension MainView {
    /// In-window screen-grant flow (#277), mirroring onboarding's
    /// request/open-settings/awaiting/auto-relaunch machinery, with a demoted
    /// return-to-onboarding fallback.
    var noPermissionsView: some View {
        VStack(spacing: Metrics.noPermissionsSpacing) {
            Spacer()
            Image(systemName: "display")
                .font(.system(size: Metrics.emptyIconSize))
                .foregroundStyle(.purple)
                .accessibilityHidden(true)
            Text("Нужен доступ к записи экрана")
                .font(.title3)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Text(self.noPermissionsSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.noPermissionsTextPaddingH)
            self.noPermissionsActionButton
            self.noPermissionsReturnButton
            Spacer()
        }
        .padding(.horizontal, Metrics.outerPaddingH)
        .modifier(NoPermissionsPollingModifier(model: self.model))
    }

    /// Body copy for the no-permissions state, mirroring onboarding's screen-card subtitle tone
    /// (calm setup-step framing, not an error) — including the auto-detection reassurance so the
    /// user is not surprised by the awaiting state after switching to System Settings and back.
    private var noPermissionsSubtitle: String {
        if self.model.isAwaitingScreen {
            return "Ожидаем включения в Системных настройках."
        }
        return "Для записи нужен доступ к записи экрана. Откройте Системные настройки и включите его " +
            "для Onset — статус обновится сам."
    }

    /// "Открыть настройки" stays the PRIMARY action in both the initial and awaiting branches
    /// (mirrors `OnboardingView.screenCardButton`, which keeps the button for every
    /// non-authorized status). While awaiting, a secondary spinner + "Проверить снова" row is
    /// appended below it — losing the reopen-Settings CTA once awaiting starts would strand a
    /// user who closed Settings without granting (see `MainViewModel.leaveNoPermissionsState`).
    @ViewBuilder
    private var noPermissionsActionButton: some View {
        Button("Открыть настройки") {
            self.model.openScreenRecordingSettings()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Открыть настройки записи экрана")
        .accessibilityIdentifier("no-permissions-open-settings-button")
        if self.model.isAwaitingScreen {
            self.noPermissionsAwaitingSecondary
        }
    }

    /// Secondary awaiting affordance: spinner + explicit recheck, shown alongside (not instead
    /// of) the primary "Открыть настройки" button.
    private var noPermissionsAwaitingSecondary: some View {
        VStack(spacing: Metrics.rowSpacing) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Button("Проверить снова") {
                self.model.checkScreenStatusNow()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("no-permissions-recheck-button")
        }
    }

    /// Demoted fallback escape hatch: kept for cases where the in-window grant
    /// flow does not apply (e.g. the user prefers reviewing all three permissions).
    private var noPermissionsReturnButton: some View {
        Button("Вернуться к разрешениям") {
            // Clear the transient awaiting flag before leaving: MainViewModel is app-lifetime,
            // so a later re-entry into this state must not show a stale "Ожидание…" spinner.
            self.model.leaveNoPermissionsState()
            self.onReturnToOnboarding()
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("no-permissions-return-button")
    }
}

// MARK: - NoPermissionsPollingModifier

/// Polls screen status while the no-permissions state is shown; mirrors OnboardingView's
/// structured-cancellation lifecycle so the loop stops when the state is left.
///
/// Factored out of `noPermissionsView` as a `ViewModifier` so the top-level `VStack`
/// closure stays short — the `.task(id:)` body itself has no bearing on that count once
/// extracted into its own attached type.
private struct NoPermissionsPollingModifier: ViewModifier {
    let model: MainViewModel

    /// Re-arm relies on `noPermissionsView` also reading `model.isAwaitingScreen` in its own
    /// body (for the primary/secondary button split above); a refactor that stops reading it
    /// there could silently weaken this `.task(id:)` re-arm.
    func body(content: Content) -> some View {
        content
            .task(id: self.model.isAwaitingScreen) {
                guard self.model.isAwaitingScreen else { return }
                let pollingTask = self.model.startScreenPolling()
                await withTaskCancellationHandler {
                    await pollingTask.value
                } onCancel: {
                    pollingTask.cancel()
                }
            }
    }
}
