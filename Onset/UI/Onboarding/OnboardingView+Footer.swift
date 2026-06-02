import SwiftUI

// MARK: - Footer sub-views

/// Footer section (progress bar + graceful buttons) extracted to keep `OnboardingView`
/// struct body under the `type_body_length` lint limit.
extension OnboardingView {
    // MARK: - Footer container

    var footerSection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.footerTextSpacing) {
                self.progressBar
                HStack(spacing: Metrics.footerTextSpacing) {
                    Text("\(viewModel.progress) из 3")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.progressHintText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: Metrics.footerHSpacing)

            self.footerButtons
        }
        .padding(Metrics.contentPadding)
    }

    // MARK: - Progress bar

    var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Metrics.progressBarCornerRadius)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: Metrics.progressBarHeight)
                RoundedRectangle(cornerRadius: Metrics.progressBarCornerRadius)
                    .fill(Color.accentColor)
                    .frame(
                        width: proxy.size.width * self.progressFraction,
                        height: Metrics.progressBarHeight
                    )
                    .animation(.easeInOut, value: viewModel.progress)
            }
        }
        .frame(height: Metrics.progressBarHeight)
        .accessibilityLabel("Прогресс: \(viewModel.progress) из 3 разрешений выдано")
        .accessibilityValue("\(viewModel.progress) из 3")
    }

    var progressFraction: CGFloat {
        guard viewModel.progress > 0 else { return 0 }
        return CGFloat(viewModel.progress) / Metrics.progressTotalCount
    }

    // MARK: - Footer buttons

    var checkAgainButton: some View {
        Button {
            viewModel.checkNow()
        } label: {
            Label("Проверить снова", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    var footerButtons: some View {
        if viewModel.isAwaitingScreen {
            self.awaitingFooterButtons
        } else {
            self.normalFooterButtons
        }
    }

    /// Footer for the "Ожидание…" state — shows «Проверить снова» plus
    /// «Продолжить без экрана» when camera is already available (AC-7).
    var awaitingFooterButtons: some View {
        HStack(spacing: Metrics.footerHSpacing) {
            if viewModel.canContinueWithoutScreen {
                // Available whenever screen is not granted AND camera is available —
                // not gated on any denied state (AC-6/AC-7 amendment).
                Button("Продолжить без экрана") {
                    onProceedToMain()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            self.checkAgainButton
        }
    }

    var normalFooterButtons: some View {
        HStack(spacing: Metrics.footerHSpacing) {
            if viewModel.canRecordWithoutAudio {
                Button("Записать без звука") {
                    onProceedToMain()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            if !viewModel.effectivePermissions.canRecord {
                Button("Позже") {
                    onProceedToMain()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button("Продолжить") {
                onProceedToMain()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canContinue)
        }
    }
}
