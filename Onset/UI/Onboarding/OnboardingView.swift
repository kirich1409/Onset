import SwiftUI

// MARK: - OnboardingView

/// The main onboarding screen shown when one or more permissions are not yet granted.
///
/// Composes the header, optional denied-screen banner, three permission cards,
/// footer graceful-degradation links + primary button, and the "N из 3" progress bar.
///
/// Polling lifecycle: starts via `.task` when this view appears; the task's cancellation
/// propagates into `PermissionsService.startScreenPolling()`'s returned `Task`, so the
/// polling loop stops automatically when the view disappears or is replaced.
///
/// Sub-view extensions:
/// - `OnboardingView+DeviceCards.swift` — camera + microphone cards
/// - `OnboardingView+Footer.swift` — footer section, progress bar, footer buttons
/// - `OnboardingView+Previews.swift` — `#Preview` blocks + `PreviewPermissionsService`
struct OnboardingView: View {
    // MARK: - Metrics

    enum Metrics {
        static let windowWidth: CGFloat = 460
        static let headerIconSize: CGFloat = 56
        static let headerIconCornerRadius: CGFloat = 12
        static let headerHSpacing: CGFloat = 12
        static let headerBottomPadding: CGFloat = 4
        static let headerTextSpacing: CGFloat = 4
        static let sectionSpacing: CGFloat = 10
        static let cardStackSpacing: CGFloat = 8
        static let contentPadding: CGFloat = 20
        static let progressBarHeight: CGFloat = 4
        static let progressBarCornerRadius: CGFloat = 2
        static let footerHSpacing: CGFloat = 12
        static let footerTextSpacing: CGFloat = 4
        static let bannerCornerRadius: CGFloat = 10
        static let bannerHPadding: CGFloat = 12
        static let bannerVPadding: CGFloat = 10
        static let bannerIconSpacing: CGFloat = 8
        static let bannerBorderOpacity: CGFloat = 0.30
        static let bannerFillOpacity: CGFloat = 0.10
        static let bannerBorderWidth: CGFloat = 1
        static let progressTotalCount: CGFloat = 3
    }

    // MARK: - Inputs

    /// The view-model driving this screen.
    let viewModel: OnboardingViewModel
    /// Called when the user wants to navigate to the recording screen (graceful or full).
    let onProceedToMain: () -> Void

    // MARK: - Local state

    /// Controls the expandable instructions on the screen-recording card.
    @State private var showScreenInstructions = true

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    self.headerSection
                    if self.viewModel.showDeniedScreenBanner {
                        self.deniedBanner
                    }
                    self.cardsSection
                }
                .padding(Metrics.contentPadding)
            }

            Divider()
            footerSection
        }
        .frame(width: Metrics.windowWidth)
        // Start polling when this view is active; cancels on disappear (structured task).
        .task {
            let pollingTask = self.viewModel.startPolling()
            await withTaskCancellationHandler {
                await pollingTask.value
            } onCancel: {
                pollingTask.cancel()
            }
        }
        // Refresh status on app-foreground (catches revoke-in-Settings).
        .onChange(of: self.scenePhase) { _, newPhase in
            if newPhase == .active {
                self.viewModel.refresh()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: Metrics.headerHSpacing) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: Metrics.headerIconSize, height: Metrics.headerIconSize)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.headerIconCornerRadius))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.headerTextSpacing) {
                Text("Onset нужны разрешения")
                    .font(.headline)
                Text(self.headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Metrics.headerBottomPadding)
    }

    private var headerSubtitle: String {
        if self.viewModel.showDeniedScreenBanner {
            return "Запись экрана отклонена. Её нужно включить вручную — системный запрос больше не появится."
        }
        if self.viewModel.isAwaitingScreen, self.viewModel.screenStatus == .notDetermined {
            return "Onset открыл Системные настройки. Включите доступ к записи экрана — мы поймём это сами."
        }
        return "Onset один раз попросит доступ к экрану, камере и микрофону. Данные никуда не отправляются."
    }

    // MARK: - Denied banner

    private var deniedBanner: some View {
        HStack(alignment: .top, spacing: Metrics.bannerIconSpacing) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(
                "Доступ к записи экрана запрещён. macOS заблокировал захват экрана для Onset. " +
                    "Пока доступ не включён в настройках, можно записывать только камеру и звук."
            )
            .font(.footnote)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.bannerHPadding)
        .padding(.vertical, Metrics.bannerVPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.bannerCornerRadius)
                .fill(Color.red.opacity(Metrics.bannerFillOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.bannerCornerRadius)
                        .strokeBorder(
                            Color.red.opacity(Metrics.bannerBorderOpacity),
                            lineWidth: Metrics.bannerBorderWidth
                        )
                )
        )
        .accessibilityLabel("Доступ к записи экрана запрещён. Можно записывать только камеру и звук.")
    }

    // MARK: - Cards

    // Camera and microphone card view builders live in OnboardingView+DeviceCards.swift.

    private var cardsSection: some View {
        VStack(spacing: Metrics.cardStackSpacing) {
            self.screenCard
            cameraCard
            microphoneCard
        }
    }

    // MARK: Screen card

    @ViewBuilder
    private var screenCard: some View {
        let cardStatus = self.screenCardStatus
        let showButton = cardStatus != .authorized
        PermissionCardView(
            iconSymbol: "display",
            iconColor: .purple,
            title: "Запись экрана",
            subtitle: self.screenCardSubtitle,
            status: cardStatus,
            actionButton: showButton ? self.screenCardButton : nil,
            instructions: self.screenCardInstructions,
            showInstructions: self.$showScreenInstructions
        )
    }

    private var screenCardStatus: PermissionCardStatus {
        // isAwaitingScreen is a transient UI flag set when the user opens Settings.
        // Actual status wins when it resolves to a definitive state — prevents the
        // denied banner and "Ожидание…" chip from appearing simultaneously.
        switch self.viewModel.screenStatus {
        case .notDetermined:
            self.viewModel.isAwaitingScreen ? .awaiting : .required

        case .authorized:
            .authorized

        case .denied, .restricted:
            .denied
        }
    }

    private var screenCardSubtitle: String {
        if self.viewModel.isAwaitingScreen, self.viewModel.screenStatus == .notDetermined {
            return "Ожидаем включения в Системных настройках."
        }
        switch self.viewModel.screenStatus {
        case .notDetermined:
            return "Чтобы захватывать ваш дисплей."

        case .authorized:
            return "Захват вашего дисплея."

        case .denied, .restricted:
            return "Отклонено. Включите вручную в настройках."
        }
    }

    private var screenCardButton: PermissionCardActionButton? {
        let status = self.screenCardStatus
        guard status != .authorized else { return nil }
        return .init(
            label: "Открыть настройки",
            action: { self.viewModel.openScreenRecordingSettings() },
            style: .secondary
        )
    }

    private var screenCardInstructions: [String]? {
        let status = self.screenCardStatus
        guard status == .required || status == .awaiting || status == .denied else { return nil }
        if status == .denied {
            return [
                "Откройте **Конфиденциальность → Запись экрана**.",
                "Найдите **Onset** в списке и включите переключатель.",
                "macOS попросит **перезапустить Onset** — приложение перезапустится само.",
            ]
        }
        // required / awaiting
        return [
            "Нажмите «Открыть настройки» — Onset откроет нужный раздел.",
            "В разделе **Конфиденциальность → Запись экрана** включите переключатель напротив Onset.",
            "Вернитесь в Onset — проверка пройдёт **автоматически**.",
        ]
    }

    // MARK: - «Проверить снова» button

    // Declared in OnboardingView+Footer.swift as `checkAgainButton`.
}
