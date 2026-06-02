import SwiftUI

// MARK: - OnboardingView

/// The main onboarding screen shown when one or more permissions are not yet granted.
///
/// Composes the header, three permission cards,
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
        if self.viewModel.isAwaitingScreen, self.viewModel.screenStatus == .notDetermined {
            return "Onset открыл Системные настройки. Включите доступ к записи экрана — мы поймём это сами."
        }
        // Mic-remaining: screen + camera granted, only mic left (matching mockup "_ _(1).png").
        let effective = self.viewModel.effectivePermissions
        if effective.screenAvailable, effective.cameraAvailable, !effective.microphoneAvailable {
            return "Почти всё готово. Осталось выдать последнее разрешение, чтобы записывать со звуком."
        }
        return "Onset один раз попросит доступ к экрану, камере и микрофону. Данные никуда не отправляются."
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
            instructionsHeader: self.screenCardInstructionsHeader,
            showInstructions: self.$showScreenInstructions
        )
    }

    private var screenCardStatus: PermissionCardStatus {
        // isAwaitingScreen is a transient UI flag set when the user opens Settings.
        // Actual status wins when it resolves to a definitive state — prevents
        // "Ожидание…" chip from sticking after the status changes.
        // Screen recording has no real denied state (CGPreflight is Bool-only),
        // so all non-authorized statuses fall back to .required ("Требуется" + Open Settings).
        switch self.viewModel.screenStatus {
        case .authorized:
            .authorized

        case .notDetermined, .denied, .restricted:
            self.viewModel.isAwaitingScreen ? .awaiting : .required
        }
    }

    private var screenCardSubtitle: String {
        if self.viewModel.isAwaitingScreen, self.viewModel.screenStatus != .authorized {
            return "Ожидаем включения в Системных настройках."
        }
        switch self.viewModel.screenStatus {
        case .notDetermined, .denied, .restricted:
            // Screen has no real denied state — treat all non-authorized statuses as "required".
            return "Чтобы захватывать ваш дисплей."

        case .authorized:
            // Show the real display description when available (matching mockup).
            return self.viewModel.primaryDisplayDescription.map { "Дисплей \($0)." } ?? "Захват вашего дисплея."
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
        switch self.screenCardStatus {
        case .required:
            [
                "Нажмите «Открыть настройки» — Onset откроет нужный раздел.",
                "В разделе **Конфиденциальность → Запись экрана** включите переключатель напротив Onset.",
                "Вернитесь в Onset — проверка пройдёт **автоматически**.",
            ]

        case .awaiting:
            // Distinct copy for the waiting state (matching mockup "_ _ _ _.png").
            [
                "Открыт раздел **Конфиденциальность → Запись экрана**.",
                "Включите переключатель напротив **Onset** в списке приложений.",
                "Можно не возвращаться вручную — статус обновится сам.",
            ]

        case .authorized, .denied:
            nil
        }
    }

    /// Section header shown above the screen recording instructions.
    ///
    /// State-dependent: required → «КАК ВЫДАТЬ ЗАПИСЬ ЭКРАНА»; awaiting → «ЖДЁМ РАЗРЕШЕНИЕ».
    private var screenCardInstructionsHeader: String? {
        switch self.screenCardStatus {
        case .required:
            "КАК ВЫДАТЬ ЗАПИСЬ ЭКРАНА"

        case .awaiting:
            "ЖДЁМ РАЗРЕШЕНИЕ"

        case .authorized, .denied:
            nil
        }
    }

    // MARK: - «Проверить снова» button

    // Declared in OnboardingView+Footer.swift as `checkAgainButton`.
}
